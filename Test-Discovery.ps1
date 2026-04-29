<#
.SYNOPSIS
    Discovery test for AutoMapNetworkDrives.

.DESCRIPTION
    Auto-detects the local subnet, probes TCP 445 in parallel, resolves hostnames
    for responsive hosts, and enumerates SMB shares on each. Prints a summary to
    the console showing which shares would be mapped vs skipped under the v1
    filtering rules. Does not map any drives or persist any state.

    Exercises requirements FR-4 through FR-9.

.PARAMETER TimeoutMs
    Per-batch TCP 445 probe timeout in milliseconds. Default 500.

.PARAMETER Parallelism
    Maximum concurrent TCP probes per batch. Default 64.

.PARAMETER IncludeLocalHost
    If specified, the local computer's IP addresses are NOT excluded from the
    scan. Useful when testing against a share hosted on the same machine.

.EXAMPLE
    powershell -File .\Test-Discovery.ps1

.EXAMPLE
    powershell -File .\Test-Discovery.ps1 -TimeoutMs 1000 -Parallelism 32

.NOTES
    Compatible with Windows PowerShell 5.1+ and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [int]$TimeoutMs = 500,
    [int]$Parallelism = 64,
    [switch]$IncludeLocalHost
)

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
    if ($hostCount -gt 65534) {
        throw "Subnet too large to scan ($hostCount hosts)."
    }

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
    param(
        [string[]]$IPs,
        [int]$TimeoutMs,
        [int]$Parallelism
    )

    $live = New-Object System.Collections.Generic.List[string]

    for ($offset = 0; $offset -lt $IPs.Count; $offset += $Parallelism) {
        $end = [Math]::Min($offset + $Parallelism - 1, $IPs.Count - 1)
        $batch = $IPs[$offset..$end]

        $clients = @{}
        $tasks   = New-Object System.Collections.Generic.List[object]

        foreach ($ip in $batch) {
            $c = [System.Net.Sockets.TcpClient]::new()
            $clients[$ip] = $c
            $task = $c.ConnectAsync($ip, 445)
            [void]$tasks.Add([pscustomobject]@{ IP = $ip; Task = $task })
        }

        $taskArr = $tasks.Task -as [System.Threading.Tasks.Task[]]
        try {
            [System.Threading.Tasks.Task]::WaitAll($taskArr, $TimeoutMs) | Out-Null
        } catch [System.AggregateException] {
            # Faulted tasks (refused connections, etc.) throw here; ignore — we check status below.
        }

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

function Resolve-RemoteHostName {
    param([string]$IP)

    # Resolve-DnsName queries DNS + LLMNR + mDNS; covers .local hosts (NAS devices,
    # macOS, Linux with Avahi, etc.) that the legacy DNS resolver misses.
    try {
        $records = Resolve-DnsName -Name $IP -QuickTimeout -ErrorAction Stop
        $ptr = $records | Where-Object { $_.Type -eq 'PTR' } | Select-Object -First 1
        if ($ptr -and $ptr.NameHost) {
            return $ptr.NameHost.TrimEnd('.')
        }
    } catch { }

    # Fallback: legacy NetBIOS Node Status query for hosts that don't speak mDNS/LLMNR.
    try {
        $output = & nbtstat -A $IP 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in $output) {
                if ($line -match '^\s*(\S+)\s+<00>\s+UNIQUE') {
                    return $matches[1]
                }
            }
        }
    } catch { }

    return $null
}

function Get-NetErrorHint {
    param([int]$Code)
    switch ($Code) {
        5    { 'access denied - run "net use \\HOST /user:NAME" first to authenticate, then re-run.' }
        53   { 'network path not found - host may have SMB browser/SRVSVC disabled or be unreachable for enumeration. May require an authenticated session, or a different enumeration method.' }
        64   { 'network name deleted - host dropped the connection mid-enumeration.' }
        67   { 'network name cannot be found - host name unresolvable for SMB at this point.' }
        1219 { 'credential conflict - existing session to this host uses different credentials. Run "net use \\HOST /delete" and retry.' }
        1326 { 'logon failure - the username or password is incorrect.' }
        default { $null }
    }
}

function Get-RemoteShares {
    param([string]$Target)

    # Invoke via cmd to merge stderr cleanly without tripping PS 5.1's NativeCommandError handling.
    $output = & cmd /c "net view \\$Target /all 2>&1"
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        $errorLine = $output | Where-Object { $_ -match 'System error \d+' } | Select-Object -First 1
        $code = $null
        if ($errorLine -and $errorLine -match 'System error (\d+)') {
            $code = [int]$matches[1]
        }
        return [pscustomobject]@{
            Success   = $false
            ExitCode  = $exit
            ErrorCode = $code
            ErrorText = if ($errorLine) { $errorLine.Trim() } else { ($output | Out-String).Trim() }
            Hint      = if ($code) { Get-NetErrorHint -Code $code } else { $null }
            Shares    = @()
        }
    }

    $shares = New-Object System.Collections.Generic.List[object]
    foreach ($line in $output) {
        if ($line -match '^(\S+)\s+(Disk|Print|Printer|IPC)\b') {
            $name   = $matches[1]
            $type   = $matches[2]
            $hidden = $name.EndsWith('$')
            $isUserShare = ($type -eq 'Disk') -and (-not $hidden)
            [void]$shares.Add([pscustomobject]@{
                Name        = $name
                Type        = $type
                Hidden      = $hidden
                IsUserShare = $isUserShare
            })
        }
    }

    [pscustomobject]@{
        Success   = $true
        ExitCode  = 0
        ErrorCode = $null
        ErrorText = $null
        Hint      = $null
        Shares    = $shares
    }
}

# === Main ===

Write-Host "AutoMapNetworkDrives - discovery test" -ForegroundColor Cyan
Write-Host ""

$subnet = Get-LocalSubnet
Write-Host ("Active interface: {0} ({1})" -f $subnet.InterfaceAlias, $subnet.InterfaceIndex)
Write-Host ("Local IP:         {0}/{1}" -f $subnet.LocalIP, $subnet.PrefixLength)

$candidateIPs = Get-SubnetHostIPs -IP $subnet.LocalIP -PrefixLength $subnet.PrefixLength

if (-not $IncludeLocalHost) {
    $localIPs = @(Get-LocalIPv4Addresses)
    $candidateIPs = $candidateIPs | Where-Object { $_ -notin $localIPs }
}

$candidateIPs = @($candidateIPs)
Write-Host ("Scanning {0} IP(s) - timeout={1}ms, parallelism={2}" -f $candidateIPs.Count, $TimeoutMs, $Parallelism)
Write-Host ""

$start = Get-Date
$liveHosts = @(Test-HostsTcp445 -IPs $candidateIPs -TimeoutMs $TimeoutMs -Parallelism $Parallelism)
$liveHosts = @($liveHosts | Sort-Object {
    $b = [System.Net.IPAddress]::Parse($_).GetAddressBytes()
    [array]::Reverse($b)
    [BitConverter]::ToUInt32($b, 0)
})
$elapsed = (Get-Date) - $start

Write-Host ("Probe complete: {0} live SMB host(s) in {1:N1}s" -f $liveHosts.Count, $elapsed.TotalSeconds) -ForegroundColor Cyan
Write-Host ""

if ($liveHosts.Count -eq 0) {
    Write-Host "No SMB hosts found. Nothing to enumerate."
    return
}

$summary = New-Object System.Collections.Generic.List[object]

foreach ($ip in $liveHosts) {
    $name = Resolve-RemoteHostName -IP $ip
    $target = if ($name) { $name } else { $ip }
    $hostLabel = if ($name) { "$name ($ip)" } else { "$ip [no hostname]" }

    Write-Host "Host: $hostLabel" -ForegroundColor Green
    if (-not $name) {
        Write-Host "  WARN: hostname could not be resolved; mapping would fall back to IP." -ForegroundColor Yellow
    }

    $result = Get-RemoteShares -Target $target
    if (-not $result.Success) {
        $detail = if ($result.ErrorText) { $result.ErrorText } else { "net.exe exit $($result.ExitCode)" }
        Write-Host "  Could not enumerate shares: $detail" -ForegroundColor Yellow
        if ($result.Hint) {
            Write-Host "  Hint: $($result.Hint)" -ForegroundColor DarkYellow
        }
        Write-Host ""
        continue
    }

    if ($result.Shares.Count -eq 0) {
        Write-Host "  (no shares listed)"
        Write-Host ""
        continue
    }

    foreach ($s in $result.Shares) {
        $tag      = if ($s.IsUserShare) { '[MAP] ' } else { '[SKIP]' }
        $color    = if ($s.IsUserShare) { 'White' } else { 'DarkGray' }
        $hiddenTag = if ($s.Hidden) { ', hidden' } else { '' }
        Write-Host ("  {0} \\{1}\{2}  ({3}{4})" -f $tag, $target, $s.Name, $s.Type, $hiddenTag) -ForegroundColor $color

        [void]$summary.Add([pscustomobject]@{
            Host     = $target
            IP       = $ip
            Share    = $s.Name
            Type     = $s.Type
            Hidden   = $s.Hidden
            WouldMap = $s.IsUserShare
        })
    }
    Write-Host ""
}

$totalShares = $summary.Count
$mappable    = @($summary | Where-Object WouldMap).Count
$skipped     = $totalShares - $mappable

Write-Host "Summary" -ForegroundColor Cyan
Write-Host ("  Hosts probed:       {0}" -f $candidateIPs.Count)
Write-Host ("  Live SMB hosts:     {0}" -f $liveHosts.Count)
Write-Host ("  Shares discovered:  {0}" -f $totalShares)
Write-Host ("  Would map (user):   {0}" -f $mappable)
Write-Host ("  Would skip:         {0}" -f $skipped)

exit 0
