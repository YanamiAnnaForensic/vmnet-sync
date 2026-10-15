#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check', 'Repair')][string]$Mode = 'Check',
    [string]$ConfigDirectory = "$env:ProgramData\VMware",
    [ValidateRange(15, 120)][int]$TimeoutSeconds = 90,
    [switch]$EventMode
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Core.ps1"

function Test-Administrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ActualNetwork($Desired) {
    $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -match '^VMware Virtual Ethernet Adapter for VMnet8$' })
    $result = [ordered]@{ AdapterCount = $adapters.Count; Name = ''; Index = 0; Mac = ''; Status = ''; Addresses = @(); DhcpEnabled = $false; DirectRoute = $false; DefaultRoute = $false; ServicesRunning = $false }
    if ($adapters.Count -ne 1) { return [pscustomobject]$result }
    $adapter = $adapters[0]
    $result.Name = $adapter.Name
    $result.Index = $adapter.ifIndex
    $result.Mac = $adapter.MacAddress.Replace('-', '').ToUpperInvariant()
    $result.Status = [string]$adapter.Status
    $result.Addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object IPAddress, PrefixLength, @{n='AddressState';e={[string]$_.AddressState}}, @{n='PrefixOrigin';e={[string]$_.PrefixOrigin}})
    $interface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $result.DhcpEnabled = ([string]$interface.Dhcp -eq 'Enabled')
    $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $result.DirectRoute = @($routes | Where-Object { $_.DestinationPrefix -eq $Desired.Network -and $_.NextHop -eq '0.0.0.0' }).Count -gt 0
    $result.DefaultRoute = @($routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }).Count -gt 0
    $services = @(Get-Service -Name 'VMnetDHCP', 'VMware NAT Service')
    $result.ServicesRunning = @($services | Where-Object { $_.Status -ne 'Running' }).Count -eq 0
    return [pscustomobject]$result
}

function Invoke-AdapterRenew([string]$Alias, [int]$LimitMilliseconds) {
    if ($Alias.Contains('"')) { throw 'Unsupported quote in adapter name.' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = "$env:SystemRoot\System32\ipconfig.exe"
    $info.Arguments = '/renew "' + $Alias + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($LimitMilliseconds)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Targeted DHCP renewal timed out.'
        }
        # ipconfig exit status is not proof of synchronization; always inspect the live adapter afterward.
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result; Error = $stderr.Result }
    } finally { $process.Dispose() }
}

function Write-RunResult($Result) {
    $json = $Result | ConvertTo-Json -Depth 8
    Write-Output $json
    if ($Mode -eq 'Repair') {
        $directory = Join-Path $env:ProgramData 'Vmnet8Sync'
        if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
        # One bounded status file, rather than an ever-growing log.
        $temporary = Join-Path $directory 'last-result.tmp'
        [IO.File]::WriteAllText($temporary, $json)
        $resultPath = Join-Path $directory 'last-result.json'
        if ([IO.File]::Exists($resultPath)) { [IO.File]::Replace($temporary, $resultPath, $null) }
        else { [IO.File]::Move($temporary, $resultPath) }
    }
}

function Save-RepairSnapshot($Actual) {
    $directory = Join-Path $env:ProgramData 'Vmnet8Sync'
    if (-not (Test-Path -LiteralPath $directory)) { [void](New-Item -ItemType Directory -Path $directory) }
    [IO.File]::WriteAllText((Join-Path $directory 'before-repair.json'), ($Actual | ConvertTo-Json -Depth 8))
}

function Invoke-Synchronization {
    if ($Mode -eq 'Check') {
        $desired = Read-NetworkFiles $ConfigDirectory
        $actual = Get-ActualNetwork $desired
        $decision = Get-SyncDecision $desired $actual
        Write-RunResult ([ordered]@{ Time = (Get-Date -Format o); Mode = 'Check'; Status = $decision; Desired = $desired; Actual = $actual; Changed = $false })
        if ($decision -eq 'Synced') { return 0 }
        return 2
    }
    if (-not (Test-Administrator)) { throw 'Repair requires an elevated administrator terminal.' }
    $mutex = New-Object Threading.Mutex($false, 'Global\Vmnet8Sync.Worker')
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { Write-Output '{"Status":"Another worker is active"}'; return 0 }
        if ($EventMode) {
            . "$PSScriptRoot\Audit.ps1"
            Restore-ConfigAudit $ConfigDirectory
        }
        $auditedFingerprint = ''
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $lastHash = ''
        $stable = 0
        $attempt = 0
        $good = 0
        $changes = New-Object 'Collections.Generic.List[string]'
        $lastProblem = ''
        $desired = $null
        $actual = $null
        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            try { $desired = Read-NetworkFiles $ConfigDirectory }
            catch { $lastProblem = $_.Exception.Message; $stable = 0; $good = 0; Start-Sleep -Seconds 1; continue }
            if ($desired.Fingerprint -ne $lastHash) {
                $lastHash = $desired.Fingerprint; $stable = 0; $attempt = 0; $good = 0
            }
            $stable++
            if ($stable -lt 4) { Start-Sleep -Seconds 1; continue }
            if ($EventMode -and $auditedFingerprint -ne $desired.Fingerprint) {
                Restore-ConfigAudit $ConfigDirectory
                $auditedFingerprint = $desired.Fingerprint
            }
            $actual = Get-ActualNetwork $desired
            $decision = Get-SyncDecision $desired $actual
            if ($decision -eq 'Synced') {
                $good++
                if ($good -ge 3) {
                    Write-RunResult ([ordered]@{ Time = (Get-Date -Format o); Mode = 'Repair'; Status = 'Synced'; Desired = $desired; Actual = $actual; Changes = @($changes.ToArray()); ElapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2) })
                    return 0
                }
                Start-Sleep -Seconds 1
                continue
            }
            $good = 0
            $lastProblem = $decision
            # The editor may briefly remove the adapter while applying a configuration.
            if ($decision.StartsWith('Blocked:')) { Start-Sleep -Seconds 1; continue }
            if ($attempt -ge 2) { Start-Sleep -Seconds 1; continue }
            $remaining = [int](($TimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000)
            if ($remaining -lt 5000) { break }
            # Re-read before mutation: never repair against a superseded configuration.
            $confirmation = Read-NetworkFiles $ConfigDirectory
            if ($confirmation.Fingerprint -ne $desired.Fingerprint) { continue }
            $live = Get-ActualNetwork $confirmation
            if ((Get-SyncDecision $confirmation $live) -ne 'Repair') { continue }
            if (-not $live.ServicesRunning) {
                $lastProblem = 'Waiting for VMware services to finish applying settings.'
                Start-Sleep -Seconds 1
                continue
            }
            if ($attempt -eq 0) {
                Save-RepairSnapshot $live
            }
            $attempt++
            try {
                if ($attempt -eq 2) {
                    # A second renewal alone cannot fix a server still using stale settings.
                    # Restart only DHCP. NAT is not restarted to repair a host DHCP lease.
                    $service = Get-Service -Name 'VMnetDHCP'
                    if ($service.Status -ne 'Running') { throw 'DHCP service is not running.' }
                    if ($remaining -lt 16000) { break }
                    try {
                        $service.Stop()
                        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(5))
                        $service.Start()
                        $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(5))
                    } finally {
                        $service.Refresh()
                        if ($service.Status -eq 'Stopped') { $service.Start() }
                    }
                    $changes.Add('Restarted VMware DHCP service (affects all VMware DHCP networks)')
                }
                if ((Read-NetworkFiles $ConfigDirectory).Fingerprint -ne $desired.Fingerprint) { continue }
                $remaining = [math]::Min(15000, [int](($TimeoutSeconds - $timer.Elapsed.TotalSeconds) * 1000))
                if ($remaining -lt 1000) { break }
                $renewal = Invoke-AdapterRenew $live.Name $remaining
                $changes.Add("Renewed DHCP on $($live.Name); ipconfig exit code $($renewal.ExitCode)")
            } catch { $lastProblem = $_.Exception.Message }
            Start-Sleep -Seconds 2
        }
        Write-RunResult ([ordered]@{ Time = (Get-Date -Format o); Mode = 'Repair'; Status = 'NeedsAttention'; Reason = $lastProblem; Desired = $desired; Actual = $actual; Changes = @($changes.ToArray()); ElapsedSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 2) })
        return 2
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { $code = Invoke-Synchronization; $numbers = @($code | Where-Object { $_ -is [int] }); $code | Where-Object { $_ -isnot [int] } | Write-Output; exit $numbers[-1] }
    catch {
        try { Write-RunResult ([ordered]@{ Time=(Get-Date -Format o); Mode=$Mode; Status='Error'; Reason=$_.Exception.Message }) } catch { }
        Write-Error $_ -ErrorAction Continue
        exit 1
    }
}
