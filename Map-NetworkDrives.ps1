<#
.SYNOPSIS
    AutoMapNetworkDrives - discovers SMB hosts on the local subnet and maps
    their user shares as Windows network drives.

.DESCRIPTION
    Implements the v1 design in REQUIREMENTS.md. Runs in two modes:
      * Manual (default): writes to log AND echoes to console; in this mode
        the user is prompted for credentials when needed (FR-11.1..11.3).
      * Silent (-Silent): writes only to log; skips any host without stored
        credentials (FR-11.4). Intended for the at-login Task Scheduler entry.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+ (NFR-1).

.PARAMETER Silent
    Suppresses console output and disables interactive credential prompts.

.PARAMETER DryRun
    Discovery and enumeration are performed and logged, but no drives are
    mapped, no config is written, and no labels are set.

.PARAMETER TimeoutMs
    Per-batch TCP 445 probe timeout in milliseconds. Overrides config.

.PARAMETER Parallelism
    Maximum concurrent TCP probes per batch. Overrides config.

.NOTES
    Logs:    %LOCALAPPDATA%\AutoMapNetworkDrives\logs\map.log
    Config:  %APPDATA%\AutoMapNetworkDrives\config.json
#>

[CmdletBinding()]
param(
    [switch]$Silent,
    [switch]$DryRun,
    [int]$TimeoutMs = 0,
    [int]$Parallelism = 0
)

# === Constants ===

$Script:AppName    = 'AutoMapNetworkDrives'
$Script:ConfigDir  = Join-Path $env:APPDATA $Script:AppName
$Script:ConfigPath = Join-Path $Script:ConfigDir 'config.json'
$Script:LogDir     = Join-Path $env:LOCALAPPDATA "$($Script:AppName)\logs"
$Script:LogPath    = Join-Path $Script:LogDir 'map.log'
$Script:LogMaxBytes = 5 * 1024 * 1024
$Script:LogKeep     = 3
# NOTE: do NOT initialize $Script:Silent or $Script:DryRun here — those are
# the same variables as the param-block switches (params are script-scoped).
# Reassigning them to $false would overwrite the user's command-line input.

# === Logging (FR-29..FR-33) ===

function Invoke-LogRotate {
    if (-not (Test-Path $Script:LogPath)) { return }
    $size = (Get-Item -Path $Script:LogPath).Length
    if ($size -lt $Script:LogMaxBytes) { return }
    for ($i = $Script:LogKeep; $i -ge 1; $i--) {
        $src = if ($i -eq 1) { $Script:LogPath } else { "$Script:LogPath.$($i - 1)" }
        $dst = "$Script:LogPath.$i"
        if (Test-Path $src) {
            if (Test-Path $dst) { Remove-Item -Path $dst -Force -ErrorAction SilentlyContinue -WhatIf:$false }
            Move-Item -Path $src -Destination $dst -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force -WhatIf:$false | Out-Null
    }
    Invoke-LogRotate
    $line = "{0} {1,-5} {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $Script:LogPath -Value $line -Encoding UTF8 -WhatIf:$false

    if (-not $Script:Silent) {
        $color = switch ($Level) {
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

# === Config (FR-24..FR-28) ===

function Get-DefaultConfig {
    [pscustomobject]@{
        schemaVersion = 1
        scan          = [pscustomobject]@{
            timeoutMs   = 500
            parallelism = 64
        }
        mappings      = @()
    }
}

function Read-Config {
    if (-not (Test-Path $Script:ConfigPath)) {
        $cfg = Get-DefaultConfig
        Write-Config -Config $cfg
        Write-Log "Created default config at $Script:ConfigPath"
        return $cfg
    }
    try {
        $cfg = Get-Content -Path $Script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (-not $cfg.scan)      { $cfg | Add-Member -NotePropertyName scan      -NotePropertyValue ([pscustomobject]@{ timeoutMs = 500; parallelism = 64 }) -Force }
        if (-not $cfg.mappings)  { $cfg | Add-Member -NotePropertyName mappings  -NotePropertyValue @() -Force }
        return $cfg
    } catch {
        Write-Log "Config at $Script:ConfigPath unreadable, using defaults: $($_.Exception.Message)" -Level WARN
        return Get-DefaultConfig
    }
}

function Write-Config {
    param([Parameter(Mandatory)] $Config)
    if ($Script:DryRun) { return }
    if (-not (Test-Path $Script:ConfigDir)) {
        New-Item -ItemType Directory -Path $Script:ConfigDir -Force | Out-Null
    }
    $Config | ConvertTo-Json -Depth 10 | Set-Content -Path $Script:ConfigPath -Encoding UTF8
}

# === Single-instance (FR-3) ===

function New-SingleInstanceMutex {
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = "Global\AutoMapNetworkDrives_$sid"
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, $name, [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

# === Discovery (FR-4..FR-6) ===

function Get-LocalSubnet {
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Sort-Object -Property RouteMetric |
             Select-Object -First 1
    if (-not $route) { throw "No active IPv4 default route found." }

    $ipConfig = Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
    if (-not $ipConfig) { throw "No usable IPv4 address found on interface $($route.ifIndex)." }

    [pscustomobject]@{
        InterfaceIndex = $route.ifIndex
        InterfaceAlias = $ipConfig.InterfaceAlias
        LocalIP        = $ipConfig.IPAddress
        PrefixLength   = $ipConfig.PrefixLength
    }
}

function Get-SubnetHostIPs {
    param([string]$IP, [int]$PrefixLength)
    if ($PrefixLength -lt 16 -or $PrefixLength -gt 30) {
        throw "Prefix length /$PrefixLength is out of supported range (/16 to /30)."
    }
    $hostCount = [int][Math]::Pow(2, 32 - $PrefixLength) - 2
    if ($hostCount -gt 65534) { throw "Subnet too large to scan ($hostCount hosts)." }

    $bytes = [System.Net.IPAddress]::Parse($IP).GetAddressBytes()
    [array]::Reverse($bytes)
    $ipInt = [uint64][BitConverter]::ToUInt32($bytes, 0)

    $hostBits   = 32 - $PrefixLength
    $networkInt = ($ipInt -shr $hostBits) -shl $hostBits

    $results = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le $hostCount; $i++) {
        $hostBytes = [BitConverter]::GetBytes([uint32]($networkInt + $i))
        [array]::Reverse($hostBytes)
        [void]$results.Add(([System.Net.IPAddress]::new($hostBytes)).ToString())
    }
    $results
}

function Get-LocalIPv4Addresses {
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty IPAddress
}

function Test-HostsTcp445 {
    param([string[]]$IPs, [int]$TimeoutMs, [int]$Parallelism)
    $live = New-Object System.Collections.Generic.List[string]
    for ($offset = 0; $offset -lt $IPs.Count; $offset += $Parallelism) {
        $end = [Math]::Min($offset + $Parallelism - 1, $IPs.Count - 1)
        $batch = $IPs[$offset..$end]
        $clients = @{}
        $tasks = New-Object System.Collections.Generic.List[object]
        foreach ($ip in $batch) {
            $c = [System.Net.Sockets.TcpClient]::new()
            $clients[$ip] = $c
            [void]$tasks.Add([pscustomobject]@{ IP = $ip; Task = $c.ConnectAsync($ip, 445) })
        }
        $taskArr = $tasks.Task -as [System.Threading.Tasks.Task[]]
        try { [System.Threading.Tasks.Task]::WaitAll($taskArr, $TimeoutMs) | Out-Null } catch [System.AggregateException] { }
        foreach ($entry in $tasks) {
            $client = $clients[$entry.IP]
            if ($entry.Task.Status -eq 'RanToCompletion' -and $client.Connected) {
                [void]$live.Add($entry.IP)
            }
            try { $client.Close() } catch { }
            try { $client.Dispose() } catch { }
        }
    }
    $live
}

# === Hostname resolution (FR-7) ===

function Resolve-RemoteHostName {
    param([string]$IP)
    try {
        $records = Resolve-DnsName -Name $IP -QuickTimeout -ErrorAction Stop
        $ptr = $records | Where-Object { $_.Type -eq 'PTR' } | Select-Object -First 1
        if ($ptr -and $ptr.NameHost) { return $ptr.NameHost.TrimEnd('.') }
    } catch { }
    try {
        $output = & nbtstat -A $IP 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $output) {
                if ($line -match '^\s*(\S+)\s+<00>\s+UNIQUE') { return $matches[1] }
            }
        }
    } catch { }
    return $null
}

function Get-ShortHostName {
    param([string]$ResolvedName)
    if ([string]::IsNullOrWhiteSpace($ResolvedName)) { return $null }
    return ($ResolvedName -split '\.')[0]
}

# === Credentials (FR-11..FR-13) — stub, implemented in next commit ===

function Get-StoredCredential {
    param([string]$Host)
    # TODO: read from Windows Credential Manager
    return $null
}

# === Authenticated SMB session (FR-12.1) — stub ===

function Connect-AuthenticatedSmbSession {
    param([string]$Host, [pscredential]$Credential)
    # TODO: net use \\HOST\IPC$ /user:NAME password
    throw "Connect-AuthenticatedSmbSession not implemented yet"
}

# === Share enumeration (FR-8, WNetEnumResource per spike) ===

# P/Invoke wrapper for mpr.dll WNetEnumResource — same API File Explorer uses
# to browse \\HOST. Auto-filters out IPC$ and admin shares. Requires that an
# authenticated SMB session to the host already exists (FR-12.1).
if (-not ('AutoMapNetworkDrives.WNet' -as [type])) {
    $wnetSrc = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AutoMapNetworkDrives {
    public static class WNet {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        public class NETRESOURCE {
            public int dwScope;
            public int dwType;
            public int dwDisplayType;
            public int dwUsage;
            [MarshalAs(UnmanagedType.LPTStr)] public string lpLocalName;
            [MarshalAs(UnmanagedType.LPTStr)] public string lpRemoteName;
            [MarshalAs(UnmanagedType.LPTStr)] public string lpComment;
            [MarshalAs(UnmanagedType.LPTStr)] public string lpProvider;
        }
        [DllImport("mpr.dll", CharSet = CharSet.Auto)]
        public static extern int WNetOpenEnum(int dwScope, int dwType, int dwUsage, NETRESOURCE lpNetResource, out IntPtr lphEnum);
        [DllImport("mpr.dll", CharSet = CharSet.Auto)]
        public static extern int WNetEnumResource(IntPtr hEnum, ref int lpcCount, IntPtr lpBuffer, ref int lpBufferSize);
        [DllImport("mpr.dll")]
        public static extern int WNetCloseEnum(IntPtr hEnum);

        public static List<string[]> EnumShares(string remoteName) {
            var result = new List<string[]>();
            var root = new NETRESOURCE {
                dwScope = 2, dwType = 1, dwUsage = 0, lpRemoteName = remoteName
            };
            IntPtr hEnum = IntPtr.Zero;
            int rc = WNetOpenEnum(2, 1, 0, root, out hEnum);
            if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);
            try {
                int bufSize = 16384;
                IntPtr buf = Marshal.AllocHGlobal(bufSize);
                try {
                    while (true) {
                        int count = -1;
                        int sz = bufSize;
                        int er = WNetEnumResource(hEnum, ref count, buf, ref sz);
                        if (er == 259) break;
                        if (er != 0) throw new System.ComponentModel.Win32Exception(er);
                        int structSize = Marshal.SizeOf(typeof(NETRESOURCE));
                        for (int i = 0; i < count; i++) {
                            var nr = (NETRESOURCE)Marshal.PtrToStructure(IntPtr.Add(buf, i * structSize), typeof(NETRESOURCE));
                            result.Add(new[] { nr.lpRemoteName ?? "", nr.lpComment ?? "" });
                        }
                    }
                } finally { Marshal.FreeHGlobal(buf); }
            } finally { WNetCloseEnum(hEnum); }
            return result;
        }
    }
}
"@
    Add-Type -TypeDefinition $wnetSrc -ErrorAction Stop
}

function Get-RemoteSharesViaWNet {
    param([Parameter(Mandatory)] [string]$ServerName)

    $remote = "\\$ServerName"
    try {
        $entries = [AutoMapNetworkDrives.WNet]::EnumShares($remote)
    } catch {
        return [pscustomobject]@{
            Success = $false
            ErrorCode = $_.Exception.NativeErrorCode
            Error = $_.Exception.Message
            Shares = @()
        }
    }

    $shares = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        $unc = $e[0]
        $comment = $e[1]
        # WNetEnumResource returns disk shares only; still defensive-filter against
        # anything ending in $ in case an exotic provider surfaces hidden shares.
        $name = ($unc -split '\\')[-1]
        if ($name.EndsWith('$')) { continue }
        [void]$shares.Add([pscustomobject]@{
            UNC     = $unc
            Name    = $name
            Comment = $comment
        })
    }

    [pscustomobject]@{
        Success = $true
        ErrorCode = 0
        Error = $null
        Shares = $shares
    }
}

# === Drive letter assignment (FR-14, FR-15) ===

function Get-UsedDriveLetters {
    # Returns letters currently in use by ANY drive (local or network).
    $letters = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Name.Length -eq 1) { [void]$letters.Add($d.Name.ToUpper()) }
    }
    foreach ($m in (Get-SmbMapping -ErrorAction SilentlyContinue)) {
        if ($m.LocalPath -match '^([A-Z]):') { [void]$letters.Add($matches[1]) }
    }
    return $letters
}

function Get-NextFreeDriveLetter {
    param([string[]]$Reserved = @())
    $used = Get-UsedDriveLetters
    $reservedUpper = @($Reserved | ForEach-Object { $_.ToUpper() })
    foreach ($code in 90..68) {  # Z..D
        $letter = [char]$code
        if ($used.Contains([string]$letter)) { continue }
        if ($reservedUpper -contains [string]$letter) { continue }
        return [string]$letter
    }
    return $null
}

function Get-LetterForUnc {
    param(
        [Parameter(Mandatory)] [string]$UNC,
        [Parameter(Mandatory)] $Config
    )
    $existing = $Config.mappings | Where-Object { $_.unc -eq $UNC } | Select-Object -First 1
    if ($existing) {
        return [pscustomobject]@{ Letter = $existing.letter.ToUpper(); FromConfig = $true; Persistent = [bool]$existing.persistent }
    }
    $reserved = @($Config.mappings | ForEach-Object { $_.letter })
    $letter = Get-NextFreeDriveLetter -Reserved $reserved
    if (-not $letter) { return $null }
    return [pscustomobject]@{ Letter = $letter; FromConfig = $false; Persistent = $false }
}

# === Mapping + label (FR-16, FR-17, FR-34..FR-38) ===

function Get-MountPointRegPath {
    param([Parameter(Mandatory)] [string]$UNC)
    # \\HOST\share -> HKCU:\...\MountPoints2\##HOST#share
    $stripped = $UNC -replace '^\\\\', ''
    $key = '##' + ($stripped -replace '\\', '#')
    return "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\$key"
}

function Set-NetworkDriveLabel {
    param(
        [Parameter(Mandatory)] [string]$UNC,
        [Parameter(Mandatory)] [string]$ShareName,
        [Parameter(Mandatory)] [string]$ShortHostName
    )
    $label = "$ShareName on $ShortHostName"
    if ($Script:DryRun) {
        Write-Log "[dry-run] Would set label '$label' for $UNC"
        return
    }
    $regPath = Get-MountPointRegPath -UNC $UNC
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name '_LabelFromReg' -Value $label -Type String -Force -ErrorAction Stop
    Write-Log "Set label '$label' for $UNC"
}

function New-MappedDrive {
    param(
        [Parameter(Mandatory)] [string]$Letter,
        [Parameter(Mandatory)] [string]$UNC,
        [Parameter(Mandatory)] [bool]$Persistent
    )
    if ($Script:DryRun) {
        Write-Log "[dry-run] Would map ${Letter}: -> $UNC (persistent=$Persistent)"
        return $true
    }
    try {
        New-SmbMapping -LocalPath "${Letter}:" -RemotePath $UNC -Persistent:$Persistent -ErrorAction Stop | Out-Null
        Write-Log "Mapped ${Letter}: -> $UNC (persistent=$Persistent)"
        return $true
    } catch {
        Write-Log "Failed to map ${Letter}: -> $UNC : $($_.Exception.Message)" -Level ERROR
        return $false
    }
}

function Test-MappingConflict {
    param(
        [Parameter(Mandatory)] [string]$Letter,
        [Parameter(Mandatory)] [string]$UNC
    )
    # Returns one of: 'NoOp' | 'Free' | 'LetterTaken' | 'AlreadyElsewhere'
    $byLetter = Get-SmbMapping -LocalPath "${Letter}:" -ErrorAction SilentlyContinue
    if ($byLetter -and $byLetter.RemotePath -ieq $UNC) { return 'NoOp' }
    if ($byLetter) { return 'LetterTaken' }
    $byUnc = Get-SmbMapping -RemotePath $UNC -ErrorAction SilentlyContinue
    if ($byUnc) { return 'AlreadyElsewhere' }
    $used = Get-UsedDriveLetters
    if ($used.Contains([string]$Letter.ToUpper())) { return 'LetterTaken' }
    return 'Free'
}

function Add-ConfigMapping {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$UNC,
        [Parameter(Mandatory)] [string]$Letter,
        [Parameter(Mandatory)] [bool]$Persistent
    )
    $entry = [pscustomobject]@{ unc = $UNC; letter = $Letter; persistent = $Persistent }
    $list = New-Object System.Collections.Generic.List[object]
    if ($Config.mappings) { foreach ($m in $Config.mappings) { [void]$list.Add($m) } }
    [void]$list.Add($entry)
    $Config.mappings = $list.ToArray()
}

# === Main ===

# $DryRun and $Silent are already script-scoped via the param block; functions
# can read them directly (or via $Script:DryRun / $Script:Silent — same thing).

$mutex = New-SingleInstanceMutex
if (-not $mutex) {
    Write-Log "Another instance is already running; exiting." -Level WARN
    exit 0
}
$exitCode = 0
try {
    Write-Log "AutoMapNetworkDrives starting (mode: $(if ($Script:Silent) {'silent'} else {'manual'}), dryRun: $Script:DryRun)"

    $config = Read-Config
    if ($TimeoutMs -gt 0)    { $config.scan.timeoutMs   = $TimeoutMs }
    if ($Parallelism -gt 0)  { $config.scan.parallelism = $Parallelism }

    $subnet = Get-LocalSubnet
    Write-Log "Active interface: $($subnet.InterfaceAlias) ($($subnet.LocalIP)/$($subnet.PrefixLength))"

    $candidateIPs = @(Get-SubnetHostIPs -IP $subnet.LocalIP -PrefixLength $subnet.PrefixLength)
    $localIPs = @(Get-LocalIPv4Addresses)
    $candidateIPs = @($candidateIPs | Where-Object { $_ -notin $localIPs })

    Write-Log "Scanning $($candidateIPs.Count) IPs (timeoutMs=$($config.scan.timeoutMs), parallelism=$($config.scan.parallelism))"
    $start = Get-Date
    $liveIPs = @(Test-HostsTcp445 -IPs $candidateIPs -TimeoutMs $config.scan.timeoutMs -Parallelism $config.scan.parallelism)
    $elapsed = (Get-Date) - $start
    Write-Log ("Probe complete: {0} live SMB host(s) in {1:N1}s" -f $liveIPs.Count, $elapsed.TotalSeconds)

    foreach ($ip in $liveIPs) {
        $resolved = Resolve-RemoteHostName -IP $ip
        $target   = if ($resolved) { $resolved } else { $ip }
        if (-not $resolved) {
            Write-Log "Host $ip - hostname could not be resolved; UNC will use IP" -Level WARN
        }
        Write-Log "Host: $target ($ip)"

        # TODO: credentials + auth session establishment (FR-11..FR-12.1).
        # For now, rely on any pre-existing IPC$ session (e.g. from manual
        # `net use \\HOST /user:NAME` already done by the user).

        $enumResult = Get-RemoteSharesViaWNet -ServerName $target
        if (-not $enumResult.Success) {
            Write-Log ("Host {0} - share enumeration failed (Win32 {1}): {2}" -f $target, $enumResult.ErrorCode, $enumResult.Error) -Level WARN
            continue
        }
        if ($enumResult.Shares.Count -eq 0) {
            Write-Log "Host $target - no user shares listed"
            continue
        }
        $shortHost = Get-ShortHostName -ResolvedName $target
        if (-not $shortHost) { $shortHost = $target }

        foreach ($share in $enumResult.Shares) {
            Write-Log ("  Share: {0}{1}" -f $share.UNC, $(if ($share.Comment) { " [$($share.Comment)]" } else { '' }))

            $assignment = Get-LetterForUnc -UNC $share.UNC -Config $config
            if (-not $assignment) {
                Write-Log "    No drive letters available; skipping $($share.UNC)" -Level WARN
                continue
            }
            $letter = $assignment.Letter

            # NOTE: `continue` inside `switch` exits the switch, not the foreach.
            # Use a $skipShare flag to short-circuit out of this iteration after
            # a no-map decision (NoOp / AlreadyElsewhere / no-letter-available).
            $skipShare = $false
            $conflict = Test-MappingConflict -Letter $letter -UNC $share.UNC
            switch ($conflict) {
                'NoOp' {
                    Write-Log "    ${letter}: already mapped to $($share.UNC); no-op (FR-18)"
                    Set-NetworkDriveLabel -UNC $share.UNC -ShareName $share.Name -ShortHostName $shortHost
                    $skipShare = $true
                }
                'AlreadyElsewhere' {
                    Write-Log "    $($share.UNC) already mapped under a different letter; leaving as-is (FR-21)"
                    $skipShare = $true
                }
                'LetterTaken' {
                    if ($assignment.FromConfig) {
                        Write-Log "    Configured letter ${letter}: is taken; trying next free letter (FR-19/20)" -Level WARN
                    }
                    $reserved = @($config.mappings | ForEach-Object { $_.letter })
                    $newLetter = Get-NextFreeDriveLetter -Reserved $reserved
                    if (-not $newLetter) {
                        Write-Log "    No drive letters available after collision; skipping $($share.UNC)" -Level WARN
                        $skipShare = $true
                    } else {
                        $letter = $newLetter
                    }
                }
            }
            if ($skipShare) { continue }

            $mapped = New-MappedDrive -Letter $letter -UNC $share.UNC -Persistent $assignment.Persistent
            if ($mapped) {
                Set-NetworkDriveLabel -UNC $share.UNC -ShareName $share.Name -ShortHostName $shortHost
                if (-not $assignment.FromConfig) {
                    Add-ConfigMapping -Config $config -UNC $share.UNC -Letter $letter -Persistent $assignment.Persistent
                    Write-Config -Config $config
                    Write-Log "    Auto-learned: ${letter}: -> $($share.UNC) saved to config (FR-14.3)"
                }
            }
        }
    }

    Write-Log "AutoMapNetworkDrives complete"
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    $exitCode = 1
}
finally {
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch { }
        $mutex.Dispose()
    }
}

exit $exitCode
