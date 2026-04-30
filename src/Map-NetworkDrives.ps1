<#
.SYNOPSIS
    AutoMapNetworkDrives - discovers SMB hosts on the local subnet and maps
    their user shares as Windows network drives.

.DESCRIPTION
    Implements the v1 design in docs/REQUIREMENTS.md. Runs in two modes:
      * Manual (default): writes to log AND echoes to console; in this mode
        the user is prompted for credentials when needed (FR-11.1..11.3).
      * Silent (-Silent): writes only to log; skips any host without stored
        credentials (FR-11.4). Intended for the at-login Task Scheduler entry.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+ (NFR-1).

.PARAMETER Silent
    Suppresses ALL console output and disables interactive credential prompts.
    Log file is still written. Intended for batch / scripted re-runs.

.PARAMETER Detailed
    Show every log entry on the console with the full timestamp+level prefix
    (the same lines written to the log file). Useful for debugging. Without
    this flag, the console shows a concise end-user-oriented stream — host
    headers, drive map results, warnings, errors, and a summary.

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
    [switch]$Detailed,
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

function Add-LogLine {
    # Append a fully-formatted line to the log file. Always runs (modulo dry-run
    # / silent — neither suppresses log writes; both only affect side effects
    # and console). Console output is handled by the callers Write-Log /
    # Write-Status, not here.
    param([string]$Level, [string]$Message)
    if (-not (Test-Path $Script:LogDir)) {
        New-Item -ItemType Directory -Path $Script:LogDir -Force -WhatIf:$false | Out-Null
    }
    Invoke-LogRotate
    $line = "{0} {1,-5} {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $Script:LogPath -Value $line -Encoding UTF8 -WhatIf:$false
    return $line
}

function Get-LevelColor {
    param([string]$Level)
    switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
}

function Write-Log {
    # Diagnostic / verbose entry. Always written to the log file. On the console,
    # shown only when -Detailed is set (or for ERROR-level entries — those are
    # always surfaced so users see real failures even in default mode).
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $logLine = Add-LogLine -Level $Level -Message $Message
    if ($Script:Silent) { return }
    if (-not $Script:Detailed -and $Level -ne 'ERROR') { return }
    Write-Host $logLine -ForegroundColor (Get-LevelColor $Level)
}

function Write-Status {
    # End-user-facing entry. Always written to the log file AND to the console
    # (unless -Silent). Console formatting depends on -Detailed:
    #   default  → just the message (color-coded by level), clean for end users
    #   detailed → full timestamp+level prefix, matches the log file
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $logLine = Add-LogLine -Level $Level -Message $Message
    if ($Script:Silent) { return }
    $consoleText = if ($Script:Detailed) { $logLine } else { $Message }
    Write-Host $consoleText -ForegroundColor (Get-LevelColor $Level)
}

function Write-StatusBreak {
    # Blank line separator for the default (concise) console mode. Skipped in
    # detailed mode (where every line carries a timestamp anyway, so blanks
    # would just be noise) and in silent mode (no console output at all).
    if ($Script:Silent -or $Script:Detailed) { return }
    Write-Host ''
}

# === Config (FR-24..FR-28) ===

function Get-DefaultConfig {
    [pscustomobject]@{
        schemaVersion = 1
        scan          = [pscustomobject]@{
            timeoutMs   = 2000
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
        if (-not $cfg.scan)      { $cfg | Add-Member -NotePropertyName scan      -NotePropertyValue ([pscustomobject]@{ timeoutMs = 2000; parallelism = 64 }) -Force }
        if (-not $cfg.mappings)  { $cfg | Add-Member -NotePropertyName mappings  -NotePropertyValue @() -Force }
        return $cfg
    } catch {
        Write-Status "Config at $Script:ConfigPath unreadable, using defaults: $($_.Exception.Message)" -Level WARN
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

# === Credential Manager I/O (FR-11.5, FR-12, FR-13, NFR-6) ===

# P/Invoke wrapper around advapi32 CredRead/CredWrite/CredDelete. Stores generic
# credentials under the target name "AutoMapNetworkDrives:<host>". The Windows
# Credential Manager handles DPAPI encryption at rest; passwords are kept in
# managed strings only briefly while in process and never written to disk by us.
if (-not ('AutoMapNetworkDrives.Cred' -as [type])) {
    $credSrc = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace AutoMapNetworkDrives {
    public static class Cred {
        public const int CRED_TYPE_GENERIC = 1;
        public const int CRED_TYPE_DOMAIN_PASSWORD = 2;
        const int CRED_PERSIST_LOCAL_MACHINE = 2;
        const int ERROR_NOT_FOUND = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL {
            public int Flags;
            public int Type;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetName;
            [MarshalAs(UnmanagedType.LPWStr)] public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            [MarshalAs(UnmanagedType.LPWStr)] public string TargetAlias;
            [MarshalAs(UnmanagedType.LPWStr)] public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credPtr);
        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite([In] ref CREDENTIAL userCredential, int flags);
        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int flags);
        [DllImport("advapi32.dll")]
        private static extern void CredFree(IntPtr buffer);

        public static bool TryRead(string target, out string user, out string secret) {
            return TryRead(target, CRED_TYPE_GENERIC, out user, out secret);
        }

        // Overload accepting a credential type. Note: for CRED_TYPE_DOMAIN_PASSWORD,
        // Windows deliberately does not return the secret blob to user-mode callers
        // (only LSA may decrypt it) — `secret` will come back empty. Target name
        // and user name are returned for both types and suffice to verify that
        // a write of the expected shape persisted.
        public static bool TryRead(string target, int credType, out string user, out string secret) {
            user = null; secret = null;
            IntPtr p = IntPtr.Zero;
            if (!CredRead(target, credType, 0, out p)) {
                int err = Marshal.GetLastWin32Error();
                if (err == ERROR_NOT_FOUND) return false;
                throw new System.ComponentModel.Win32Exception(err);
            }
            try {
                var c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
                user = c.UserName;
                int n = c.CredentialBlobSize;
                if (n > 0 && c.CredentialBlob != IntPtr.Zero) {
                    byte[] bytes = new byte[n];
                    Marshal.Copy(c.CredentialBlob, bytes, 0, n);
                    secret = Encoding.Unicode.GetString(bytes);
                } else {
                    secret = "";
                }
                return true;
            } finally { CredFree(p); }
        }

        public static void Write(string target, string user, string secret) {
            Write(target, user, secret, CRED_TYPE_GENERIC);
        }

        // Overload that accepts a credential type (CRED_TYPE_GENERIC or
        // CRED_TYPE_DOMAIN_PASSWORD). Domain Password credentials, keyed under
        // the bare server name, are what Windows looks for during persistent-
        // mapping reconnect at logon — without them, persistent SMB mappings
        // to credential-required hosts come back disconnected after reboot.
        public static void Write(string target, string user, string secret, int credType) {
            byte[] secretBytes = Encoding.Unicode.GetBytes(secret ?? "");
            IntPtr blobPtr = Marshal.AllocCoTaskMem(secretBytes.Length);
            try {
                if (secretBytes.Length > 0) {
                    Marshal.Copy(secretBytes, 0, blobPtr, secretBytes.Length);
                }
                var cred = new CREDENTIAL {
                    Flags = 0,
                    Type = credType,
                    TargetName = target,
                    Comment = null,
                    CredentialBlobSize = secretBytes.Length,
                    CredentialBlob = blobPtr,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    TargetAlias = null,
                    UserName = user
                };
                if (!CredWrite(ref cred, 0)) {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
            } finally { Marshal.FreeCoTaskMem(blobPtr); }
        }

        public static bool Delete(string target) {
            return Delete(target, CRED_TYPE_GENERIC);
        }

        public static bool Delete(string target, int credType) {
            if (CredDelete(target, credType, 0)) return true;
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND) return false;
            throw new System.ComponentModel.Win32Exception(err);
        }
    }
}
"@
    Add-Type -TypeDefinition $credSrc -ErrorAction Stop
}

function Get-CredTargetName {
    param([Parameter(Mandatory)] [string]$HostName)
    "$($Script:AppName):$HostName"
}

function Get-StoredCredential {
    param([Parameter(Mandatory)] [string]$HostName)
    $target = Get-CredTargetName -HostName $HostName
    $user   = $null
    $secret = $null
    try {
        $found = [AutoMapNetworkDrives.Cred]::TryRead($target, [ref]$user, [ref]$secret)
    } catch {
        Write-Status "Credential read failed for ${HostName}: $($_.Exception.Message)" -Level WARN
        return $null
    }
    if (-not $found) { return $null }
    $sec = ConvertTo-SecureString -String $secret -AsPlainText -Force
    return [pscredential]::new($user, $sec)
}

function Confirm-WrittenCredential {
    # Lightweight readback verification after a CredWrite. Confirms an entry
    # of the expected type exists at the expected target and carries the
    # expected user name. Catches the rare case where CredWrite returns
    # success but the entry didn't materialize, plus any future regression
    # that writes the wrong type/target/user. The password blob is NOT
    # verified — for Domain Password credentials Windows does not return
    # it to user-mode callers (only LSA decrypts), and for Generic
    # credentials the storage layer does not transform secrets, so a
    # target+user match is sufficient evidence the write succeeded as
    # written. Returns $true on success, $false otherwise (and logs WARN
    # describing the mismatch).
    param(
        [Parameter(Mandatory)] [string]$Target,
        [Parameter(Mandatory)] [int]$CredType,
        [Parameter(Mandatory)] [string]$ExpectedUser
    )
    $u = $null
    $s = $null
    try {
        $found = [AutoMapNetworkDrives.Cred]::TryRead($Target, $CredType, [ref]$u, [ref]$s)
    } catch {
        Write-Status "Could not verify credential at ${Target}: $($_.Exception.Message)" -Level WARN
        return $false
    }
    if (-not $found) {
        Write-Status "Credential verification failed: $Target not found after write" -Level WARN
        return $false
    }
    if ($u -ine $ExpectedUser) {
        Write-Status "Credential verification mismatch at ${Target}: expected user '$ExpectedUser', got '$u'" -Level WARN
        return $false
    }
    Write-Log "Verified credential for $Target"
    return $true
}

function Save-StoredCredential {
    param(
        [Parameter(Mandatory)] [string]$HostName,
        [Parameter(Mandatory)] [pscredential]$Credential
    )
    if ($Script:DryRun) {
        Write-Log "[dry-run] Would save credential for $HostName"
        return
    }
    $target = Get-CredTargetName -HostName $HostName
    $plain  = $Credential.GetNetworkCredential().Password
    [AutoMapNetworkDrives.Cred]::Write($target, $Credential.UserName, $plain, [AutoMapNetworkDrives.Cred]::CRED_TYPE_GENERIC)
    Write-Log "Stored credential in Credential Manager for $HostName"
    [void](Confirm-WrittenCredential -Target $target -CredType ([AutoMapNetworkDrives.Cred]::CRED_TYPE_GENERIC) -ExpectedUser $Credential.UserName)
}

function Register-AutoReconnectCredential {
    # Writes a Domain Password credential (CRED_TYPE_DOMAIN_PASSWORD = 2) keyed
    # under the bare host name. This is the credential format Windows looks for
    # when reconnecting persistent SMB mappings at logon. Without it, persistent
    # mappings to auth-required hosts come back as disconnected ghosts after a
    # reboot/sign-out, and clicking the drive in Explorer fails with Win32 85
    # "The local device name is already in use."
    #
    # The credential we write under "AutoMapNetworkDrives:<host>" (Generic) is
    # for our OWN reuse on the next script run; this Domain Password copy is
    # for Windows. Both encrypted at rest by DPAPI; neither written to disk
    # by us in plain text.
    param(
        [Parameter(Mandatory)] [string]$HostName,
        [Parameter(Mandatory)] [pscredential]$Credential
    )
    if ($Script:DryRun) {
        Write-Log "[dry-run] Would register Windows auto-reconnect credential for $HostName"
        return
    }
    $plain = $Credential.GetNetworkCredential().Password
    try {
        [AutoMapNetworkDrives.Cred]::Write($HostName, $Credential.UserName, $plain, [AutoMapNetworkDrives.Cred]::CRED_TYPE_DOMAIN_PASSWORD)
        Write-Log "Registered Windows auto-reconnect credential for $HostName"
        [void](Confirm-WrittenCredential -Target $HostName -CredType ([AutoMapNetworkDrives.Cred]::CRED_TYPE_DOMAIN_PASSWORD) -ExpectedUser $Credential.UserName)
    } catch {
        Write-Log "Could not register auto-reconnect credential for ${HostName}: $($_.Exception.Message)" -Level WARN
    }
}

# === Authenticated SMB session (FR-12.1) ===

function Get-Win32ErrorMessage {
    param([int]$Code)
    try { (New-Object System.ComponentModel.Win32Exception($Code)).Message }
    catch { "Win32 error $Code" }
}

function Test-AuthError {
    param([int]$ErrorCode)
    # Win32 codes that indicate authentication is the problem (vs. unreachable host etc.)
    $authCodes = @(
        5,    # ERROR_ACCESS_DENIED
        86,   # ERROR_INVALID_PASSWORD
        1326, # ERROR_LOGON_FAILURE
        1327, # ERROR_ACCOUNT_RESTRICTION
        1329, # ERROR_LOGON_TYPE_NOT_GRANTED
        1907, # ERROR_PASSWORD_MUST_CHANGE
        1909, # ERROR_ACCOUNT_LOCKED_OUT
        1910  # ERROR_ACCOUNT_DISABLED
    )
    return $authCodes -contains $ErrorCode
}

function Test-BadNetPathError {
    param([int]$ErrorCode)
    # Win32 codes that mean "the network name/path was rejected at the network
    # provider level" — distinct from auth errors. These trigger the FQDN→short
    # hostname retry per FR-7.5. All three share an identical English message
    # ("The network path was either typed incorrectly..."), so the numeric code
    # is the only way to distinguish them in code.
    $codes = @(
        53,   # ERROR_BAD_NETPATH
        67,   # ERROR_BAD_NET_NAME
        1203  # ERROR_NO_NET_OR_BAD_PATH
    )
    return $codes -contains $ErrorCode
}

function Connect-AuthenticatedSmbSession {
    param(
        [Parameter(Mandatory)] [string]$HostName,
        [Parameter(Mandatory)] [pscredential]$Credential
    )
    # Mounts \\HOST\IPC$ via WNetAddConnection2 — same API File Explorer uses.
    # Returns {Success, ErrorCode, Error}. No persistent flag (session-only).
    $unc = "\\$HostName\IPC`$"
    if ($Script:DryRun) {
        return [pscustomobject]@{ Success = $true; ErrorCode = 0; Error = $null }
    }

    $user = $Credential.UserName
    $pass = $Credential.GetNetworkCredential().Password
    # localName is null — IPC$ is an authentication-only session, no drive letter.
    $rc   = [AutoMapNetworkDrives.WNet]::AddConnection($unc, $null, $user, $pass, $false)

    # 1219 = ERROR_SESSION_CREDENTIAL_CONFLICT (a different cred is already in
    # use for this server). Tear down and retry once. We cancel only \\HOST\IPC$
    # — not \\HOST\* — to avoid disturbing user-initiated mappings to the same
    # server under different shares.
    if ($rc -eq 1219) {
        [void][AutoMapNetworkDrives.WNet]::CancelConnection($unc, $true)
        $rc = [AutoMapNetworkDrives.WNet]::AddConnection($unc, $null, $user, $pass, $false)
    }

    if ($rc -eq 0) {
        return [pscustomobject]@{ Success = $true; ErrorCode = 0; Error = $null }
    }
    [pscustomobject]@{
        Success   = $false
        ErrorCode = $rc
        Error     = (Get-Win32ErrorMessage -Code $rc)
    }
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
        [DllImport("mpr.dll", CharSet = CharSet.Auto)]
        public static extern int WNetAddConnection2(NETRESOURCE lpNetResource, string lpPassword, string lpUserName, int dwFlags);
        [DllImport("mpr.dll", CharSet = CharSet.Auto)]
        public static extern int WNetCancelConnection2(string lpName, int dwFlags, bool fForce);

        public static int AddConnection(string remoteName, string localName, string user, string password, bool persistent) {
            // localName: drive letter like "X:" to bind the mapping to a letter
            // visible in Explorer, or null for an authentication-only session
            // (e.g. \\HOST\IPC$ where no drive letter is wanted).
            var nr = new NETRESOURCE {
                dwScope = 1,    // RESOURCE_GLOBALNET
                dwType = 1,     // RESOURCETYPE_DISK
                dwUsage = 1,    // RESOURCEUSAGE_CONNECTABLE
                lpLocalName = localName,
                lpRemoteName = remoteName
            };
            int flags = persistent ? 1 : 0; // CONNECT_UPDATE_PROFILE = 1
            return WNetAddConnection2(nr, password, user, flags);
        }

        public static int CancelConnection(string name, bool force) {
            return WNetCancelConnection2(name, 0, force);
        }

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
        # When C# code throws via [type]::Method(...), PowerShell wraps the
        # exception in MethodInvocationException. The Win32Exception we threw
        # is the InnerException (or further down the chain). Unwrap so the
        # caller sees the real Win32 code and clean message.
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        $code = if ($ex -is [System.ComponentModel.Win32Exception]) { $ex.NativeErrorCode } else { 0 }
        return [pscustomobject]@{
            Success   = $false
            ErrorCode = $code
            Error     = $ex.Message
            Shares    = @()
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
    # Returns letters currently in use by ANY drive (local, network, or remembered).
    $letters = New-Object System.Collections.Generic.HashSet[string]
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Name.Length -eq 1) { [void]$letters.Add($d.Name.ToUpper()) }
    }
    foreach ($m in (Get-SmbMapping -ErrorAction SilentlyContinue)) {
        if ($m.LocalPath -match '^([A-Z]):') { [void]$letters.Add($matches[1]) }
    }
    # HKCU:\Network\<letter> stores remembered persistent network drive mappings,
    # including ones whose target is currently unreachable. Get-SmbMapping does
    # NOT reliably surface these — particularly when the share is offline — but
    # they still occupy the drive letter and cause WNetAddConnection2 to fail
    # with ERROR_ALREADY_ASSIGNED (Win32 85). Per FR-22 we leave the entry alone
    # and just treat the letter as reserved.
    if (Test-Path 'HKCU:\Network') {
        foreach ($key in (Get-ChildItem 'HKCU:\Network' -ErrorAction SilentlyContinue)) {
            if ($key.PSChildName -match '^[A-Za-z]$') {
                [void]$letters.Add($key.PSChildName.ToUpper())
            }
        }
    }
    # In-run failures: if New-SmbMapping failed for a letter earlier in this run
    # (e.g. the registry walk missed a binding the underlying API still sees),
    # don't retry that letter for subsequent shares.
    if ($Script:FailedLetters) {
        foreach ($l in $Script:FailedLetters) { [void]$letters.Add($l) }
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
        return [pscustomobject]@{ Letter = $existing.letter.ToUpper(); FromConfig = $true }
    }
    $reserved = @($Config.mappings | ForEach-Object { $_.letter })
    $letter = Get-NextFreeDriveLetter -Reserved $reserved
    if (-not $letter) { return $null }
    return [pscustomobject]@{ Letter = $letter; FromConfig = $false }
}

# === Mapping + label (FR-16, FR-34..FR-38) ===

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
        [Parameter(Mandatory)] [string]$UNC
    )
    if ($Script:DryRun) {
        Write-Status "[dry-run] Would map ${Letter}: -> $UNC"
        return $true
    }
    # Use net.exe rather than New-SmbMapping or raw WNetAddConnection2.
    # New-SmbMapping has been observed to create "ghost" mappings — visible to
    # Get-SmbMapping but not to the user's Explorer shell. Raw
    # WNetAddConnection2 with null user/password fails with Win32 1937
    # (NTLM_DISABLED) on hardened Windows 11 even when the LSA credential
    # cache holds usable credentials, because the API does not walk that
    # cache. net.exe goes through WNetUseConnection which DOES consult the
    # cache, and is the same path File Explorer's "Map network drive" wizard
    # uses. Empirically: net.exe creates drives that propagate to the shell.
    # cmd /c …2>&1 captures stderr cleanly under PS 5.1 (where bare 2>&1 on
    # a native exe produces NativeCommandError ErrorRecords that pollute $?).
    # All mappings are persistent (FR-16) — no caller-controlled toggle.
    $cmdLine = 'net.exe use "{0}:" "{1}" /persistent:yes 2>&1' -f $Letter, $UNC
    $output  = cmd /c $cmdLine
    $ec      = $LASTEXITCODE
    if ($ec -eq 0) {
        Write-Status "Mapped ${Letter}: -> $UNC"
        return $true
    }
    $errCode = 0
    foreach ($line in $output) {
        if ($line -match 'System error (\d+) has occurred') { $errCode = [int]$matches[1]; break }
    }
    Write-Status ("Failed to map {0}: -> {1} (net.exe exit {2}, Win32 {3}): {4}" -f $Letter, $UNC, $ec, $errCode, ($output -join '; ')) -Level ERROR
    # Track the failure so subsequent shares don't keep trying the same letter.
    # Get-UsedDriveLetters consults this set on each call.
    if (-not $Script:FailedLetters) {
        $Script:FailedLetters = New-Object System.Collections.Generic.HashSet[string]
    }
    [void]$Script:FailedLetters.Add($Letter.ToUpper())
    return $false
}

function Test-MappingConflict {
    param(
        [Parameter(Mandatory)] [string]$Letter,
        [Parameter(Mandatory)] [string]$UNC
    )
    # Returns one of: 'NoOp' | 'Ghost' | 'Free' | 'LetterTaken' | 'AlreadyElsewhere'
    # 'Ghost' = SMB redirector knows about the mapping but the drive letter is
    # not accessible to this session (left over from a prior elevated run, or
    # from New-SmbMapping which sometimes fails to propagate to the shell).
    # Caller should remove + rebuild on Ghost.
    $byLetter = Get-SmbMapping -LocalPath "${Letter}:" -ErrorAction SilentlyContinue
    if ($byLetter -and $byLetter.RemotePath -ieq $UNC) {
        if (Test-Path "${Letter}:\" -ErrorAction SilentlyContinue) { return 'NoOp' }
        return 'Ghost'
    }
    if ($byLetter) { return 'LetterTaken' }
    $byUnc = Get-SmbMapping -RemotePath $UNC -ErrorAction SilentlyContinue
    if ($byUnc) { return 'AlreadyElsewhere' }
    $used = Get-UsedDriveLetters
    if ($used.Contains([string]$Letter.ToUpper())) { return 'LetterTaken' }
    return 'Free'
}

function Remove-StaleSmbMapping {
    param([Parameter(Mandatory)] [string]$Letter)
    if ($Script:DryRun) {
        Write-Log "    [dry-run] Would remove stale mapping on ${Letter}:"
        return
    }
    # Try MPR cancel first (matches the API used to create new mappings); fall
    # back to Remove-SmbMapping for entries created by older script versions.
    $rc = [AutoMapNetworkDrives.WNet]::CancelConnection("${Letter}:", $true)
    if ($rc -ne 0) {
        Get-SmbMapping -LocalPath "${Letter}:" -ErrorAction SilentlyContinue |
            Remove-SmbMapping -Force -UpdateProfile -ErrorAction SilentlyContinue
    }
}

function Add-ConfigMapping {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$UNC,
        [Parameter(Mandatory)] [string]$Letter
    )
    # Persistent flag is no longer recorded — all mappings are persistent (FR-16).
    # Existing config files containing a `persistent` field are still read
    # without complaint; the field is simply ignored on the read side too.
    $entry = [pscustomobject]@{ unc = $UNC; letter = $Letter }
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
    Write-Status "Another instance is already running; exiting." -Level WARN
    exit 0
}
function Test-IsElevated {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object System.Security.Principal.WindowsPrincipal $id).IsInRole(
        [System.Security.Principal.WindowsBuiltinRole]::Administrator)
}

$exitCode = 0
$Script:FailedLetters = New-Object System.Collections.Generic.HashSet[string]
$Script:CountMapped    = 0
$Script:CountUnchanged = 0
$Script:CountSkipped   = 0
$Script:CountFailed    = 0
try {
    Write-Log "AutoMapNetworkDrives starting (mode: $(if ($Script:Silent) {'silent'} else {'manual'}), dryRun: $Script:DryRun)"
    $startMsg = "Scanning local network..."
    if ($Script:DryRun) { $startMsg += " (dry-run)" }
    Write-Status $startMsg

    # Warn on elevated execution: Windows UAC keeps drive mappings created in
    # the elevated logon session separate from the user's interactive session,
    # so mappings made here would not appear in the user's Explorer ("linked
    # connections" / EnableLinkedConnections behavior). Strongly suggest
    # re-running non-elevated unless the user has set EnableLinkedConnections.
    if ((Test-IsElevated) -and -not $Script:Silent) {
        Write-Status "Running ELEVATED - drive mappings created here will live in the admin logon session and will NOT appear in your normal Explorer." -Level WARN
        Write-Status "  Re-run from a non-elevated PowerShell/cmd window unless you have set HKLM\SYSTEM\CurrentControlSet\Control\Lsa\EnableLinkedConnections=1." -Level WARN
    }

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

    # === Phase 1: discovery + enumeration with stored credentials (FR-11.1) ===
    # For each live host: resolve hostname, try enum (works if pre-authed or if
    # the host allows anonymous enum). On auth failure, retry with creds from
    # Credential Manager (FR-12). Hosts still failing auth are deferred to
    # Phase 2 in manual mode, or skipped in silent mode (FR-11.4).

    $hostShares = New-Object 'System.Collections.Generic.Dictionary[string, object]'
    $needsCreds = New-Object System.Collections.Generic.List[string]

    foreach ($ip in $liveIPs) {
        $resolved = Resolve-RemoteHostName -IP $ip
        $target   = if ($resolved) { $resolved } else { $ip }
        if (-not $resolved) {
            Write-Status "Host $ip - hostname could not be resolved; UNC will use IP" -Level WARN
        }
        Write-StatusBreak
        Write-Status "Host: $target ($ip)"

        $enumResult = Get-RemoteSharesViaWNet -ServerName $target

        # FQDN→short retry: some routers (e.g. .example.lan) publish
        # a DNS suffix the host's SMB stack does not honor; resolution + TCP 445
        # still succeed but WNet returns one of the "bad net path" codes (53,
        # 67, 1203). If the short name yields a different (success or more
        # informative) outcome, switch $target to it so auth/UNC/label all use
        # the working name. Skipped when only an IP was resolved (FR-7.5 exception).
        if (-not $enumResult.Success -and
            (Test-BadNetPathError $enumResult.ErrorCode) -and
            $resolved -and $resolved.Contains('.')) {
            $short = Get-ShortHostName -ResolvedName $resolved
            if ($short -and $short -ne $resolved) {
                Write-Log ("  $target rejected SMB session (Win32 {0}); retrying as $short" -f $enumResult.ErrorCode)
                $retryResult = Get-RemoteSharesViaWNet -ServerName $short
                if ($retryResult.Success -or -not (Test-BadNetPathError $retryResult.ErrorCode)) {
                    $target = $short
                    $enumResult = $retryResult
                }
            }
        }

        if (-not $enumResult.Success -and (Test-AuthError $enumResult.ErrorCode)) {
            $stored = Get-StoredCredential -HostName $target
            if ($stored) {
                Write-Log "  Using stored credentials for $target"
                $auth = Connect-AuthenticatedSmbSession -HostName $target -Credential $stored
                if ($auth.Success) {
                    # Re-register the Windows-format credential each run. Cheap;
                    # heals environments where a prior script version stored
                    # only the Generic copy. CredWrite is idempotent.
                    Register-AutoReconnectCredential -HostName $target -Credential $stored
                    $enumResult = Get-RemoteSharesViaWNet -ServerName $target
                } else {
                    Write-Status ("  Stored credentials rejected for {0} (Win32 {1}): {2}" -f $target, $auth.ErrorCode, $auth.Error) -Level WARN
                }
            }
        }

        if (-not $enumResult.Success) {
            if (Test-AuthError $enumResult.ErrorCode) {
                if ($Script:Silent) {
                    Write-Status "  Host $target requires credentials; skipping (silent mode)" -Level WARN
                    $Script:CountSkipped++
                } else {
                    [void]$needsCreds.Add($target)
                    Write-Log "  Host $target deferred to credential prompt phase"
                }
            } else {
                Write-Status ("  Share enumeration failed for {0} (Win32 {1}): {2}" -f $target, $enumResult.ErrorCode, $enumResult.Error) -Level WARN
                $Script:CountSkipped++
            }
            continue
        }

        if ($enumResult.Shares.Count -eq 0) {
            Write-Status "  No user shares listed on $target"
            continue
        }
        $hostShares[$target] = $enumResult.Shares
    }

    # === Phase 2: batched credential prompt (FR-11.2) — manual mode only ===

    if ($Script:DryRun -and -not $Script:Silent -and $needsCreds.Count -gt 0) {
        Write-StatusBreak
        Write-Status "[dry-run] $($needsCreds.Count) host(s) would be prompted for credentials:"
        foreach ($h in $needsCreds) { Write-Status "  - $h" }
    }
    elseif (-not $Script:Silent -and -not $Script:DryRun -and $needsCreds.Count -gt 0) {
        Write-StatusBreak
        Write-Status "$($needsCreds.Count) host(s) require credentials:"
        foreach ($h in $needsCreds) { Write-Status "  - $h" }

        foreach ($target in $needsCreds) {
            # Retry on mistyped credentials. 1326 (LOGON_FAILURE) and 86
            # (INVALID_PASSWORD) are the typo signals — offer the user a
            # second/third chance. Other auth errors (account locked, disabled,
            # password expired) skip immediately because re-prompting won't
            # help and could trigger lockout. Capped at 3 attempts total.
            $maxAttempts    = 3
            $cred           = $null
            $authSucceeded  = $false
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                try {
                    $cred = Get-Credential -Message "Credentials for \\$target"
                } catch {
                    Write-Status "  Credential prompt failed for ${target}: $($_.Exception.Message)" -Level WARN
                    break
                }
                if (-not $cred) {
                    Write-Status "  No credentials provided for $target; skipping" -Level WARN
                    break
                }

                $auth = Connect-AuthenticatedSmbSession -HostName $target -Credential $cred
                if ($auth.Success) { $authSucceeded = $true; break }

                Write-Status ("  Authentication failed for {0} (Win32 {1}): {2}" -f $target, $auth.ErrorCode, $auth.Error) -Level WARN

                $isTypo = ($auth.ErrorCode -eq 1326) -or ($auth.ErrorCode -eq 86)
                if (-not $isTypo) { break }
                if ($attempt -ge $maxAttempts) {
                    Write-Status "  Maximum retry attempts reached for $target; skipping." -Level WARN
                    break
                }
                $reply = Read-Host -Prompt "  Try again? [Y/n]"
                if ($reply -match '^[nN]') { break }
            }

            if (-not $authSucceeded) {
                $Script:CountSkipped++
                continue
            }

            Save-StoredCredential -HostName $target -Credential $cred
            Register-AutoReconnectCredential -HostName $target -Credential $cred

            $enumResult = Get-RemoteSharesViaWNet -ServerName $target
            if (-not $enumResult.Success) {
                Write-Status ("  Enumeration still failing post-auth for {0} (Win32 {1}): {2}" -f $target, $enumResult.ErrorCode, $enumResult.Error) -Level WARN
                $Script:CountSkipped++
                continue
            }
            if ($enumResult.Shares.Count -eq 0) {
                Write-Status "  No user shares listed on $target"
                continue
            }
            $hostShares[$target] = $enumResult.Shares
        }
    }

    # === Phase 3: mapping (FR-11.3, FR-14..FR-21, FR-34..FR-37) ===

    foreach ($target in @($hostShares.Keys)) {
        $shortHost = Get-ShortHostName -ResolvedName $target
        if (-not $shortHost) { $shortHost = $target }

        foreach ($share in $hostShares[$target]) {
            Write-Log ("  Share: {0}{1}" -f $share.UNC, $(if ($share.Comment) { " [$($share.Comment)]" } else { '' }))

            $assignment = Get-LetterForUnc -UNC $share.UNC -Config $config
            if (-not $assignment) {
                Write-Status "    No drive letters available; skipping $($share.UNC)" -Level WARN
                $Script:CountSkipped++
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
                    $Script:CountUnchanged++
                    $skipShare = $true
                }
                'Ghost' {
                    Write-Log "    ${letter}: registered to $($share.UNC) but not visible in this session (stale); removing and remapping" -Level WARN
                    Remove-StaleSmbMapping -Letter $letter
                    # Fall through (do not set $skipShare) so the mapping below recreates it.
                }
                'AlreadyElsewhere' {
                    Write-Status "    $($share.UNC) already mapped under a different letter; leaving as-is"
                    $Script:CountUnchanged++
                    $skipShare = $true
                }
                'LetterTaken' {
                    if ($assignment.FromConfig) {
                        Write-Status "    Configured letter ${letter}: is taken; trying next free letter" -Level WARN
                    }
                    $reserved = @($config.mappings | ForEach-Object { $_.letter })
                    $newLetter = Get-NextFreeDriveLetter -Reserved $reserved
                    if (-not $newLetter) {
                        Write-Status "    No drive letters available after collision; skipping $($share.UNC)" -Level WARN
                        $Script:CountSkipped++
                        $skipShare = $true
                    } else {
                        $letter = $newLetter
                    }
                }
            }
            if ($skipShare) { continue }

            $mapped = New-MappedDrive -Letter $letter -UNC $share.UNC
            if ($mapped) {
                Set-NetworkDriveLabel -UNC $share.UNC -ShareName $share.Name -ShortHostName $shortHost
                if (-not $assignment.FromConfig) {
                    Add-ConfigMapping -Config $config -UNC $share.UNC -Letter $letter
                    Write-Config -Config $config
                    Write-Log "    Auto-learned: ${letter}: -> $($share.UNC) saved to config"
                }
                $Script:CountMapped++
            } else {
                $Script:CountFailed++
            }
        }
    }

    Write-StatusBreak
    $summary = "Done. {0} mapped, {1} unchanged, {2} skipped, {3} failed." -f `
        $Script:CountMapped, $Script:CountUnchanged, $Script:CountSkipped, $Script:CountFailed
    if ($Script:DryRun) { $summary += "  (dry-run: no changes were made)" }
    Write-Status $summary
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
