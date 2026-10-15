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
    $description = 'VMware Virtual Ethernet Adapter for ' + $Desired.Id
    $adapters = @(Get-NetAdapter -IncludeHidden | Where-Object { $_.InterfaceDescription -ieq $description })
    $result = [ordered]@{ Id=$Desired.Id; AdapterCount=$adapters.Count; Name=''; Index=0; Mac=''; Status=''; Addresses=@(); DhcpEnabled=$false; DirectRoute=$false; DefaultRoute=$false; ServicesRunning=$false }
    if ($adapters.Count -ne 1) { return [pscustomobject]$result }
    $adapter = $adapters[0]
    $result.Name = $adapter.Name; $result.Index = $adapter.ifIndex
    $result.Mac = $adapter.MacAddress.Replace('-', '').ToUpperInvariant()
    $result.Status = [string]$adapter.Status
    $result.Addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object IPAddress, PrefixLength, @{n='AddressState';e={[string]$_.AddressState}}, @{n='PrefixOrigin';e={[string]$_.PrefixOrigin}})
    $interface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4
    $result.DhcpEnabled = ([string]$interface.Dhcp -eq 'Enabled')
    $routes = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $result.DirectRoute = @($routes | Where-Object { $_.DestinationPrefix -eq $Desired.Network -and $_.NextHop -eq '0.0.0.0' }).Count -gt 0
    $result.DefaultRoute = @($routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }).Count -gt 0
    $names = @('VMnetDHCP')
    if ($Desired.Kind -eq 'NAT') { $names += 'VMware NAT Service' }
    $services = @(Get-Service -Name $names -ErrorAction SilentlyContinue)
    $result.ServicesRunning = $services.Count -eq $names.Count -and @($services | Where-Object { $_.Status -ne 'Running' }).Count -eq 0
    return [pscustomobject]$result
}

function Invoke-AdapterRenew([string]$Alias, [int]$LimitMilliseconds, [switch]$Rebind) {
    if (-not $Rebind) { return Invoke-TargetIpConfig $Alias 'renew' $LimitMilliseconds }
    # A renewal can ACK the old address even after VMware changes subnet.
    # Drop only this DHCP lease before requesting a fresh reservation.
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try { $release=Invoke-TargetIpConfig $Alias 'release' ([math]::Min(5000,$LimitMilliseconds)) }
    catch { $release=[pscustomobject]@{Output='';Error=$_.Exception.Message} }
    $remaining=[math]::Max(1000,($LimitMilliseconds-[int]$watch.Elapsed.TotalMilliseconds))
    $renew=Invoke-TargetIpConfig $Alias 'renew' $remaining
    return [pscustomobject]@{ExitCode=$renew.ExitCode;Output=($release.Output+$renew.Output);Error=($release.Error+$renew.Error)}
}

function Invoke-TargetIpConfig([string]$Alias, [ValidateSet('renew','release')][string]$Operation, [int]$LimitMilliseconds) {
    if ($Alias -match '["*?]') { throw 'Unsupported quote or wildcard in adapter name.' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = "$env:SystemRoot\System32\ipconfig.exe"
    $info.Arguments = '/' + $Operation + ' "' + $Alias + '"'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($LimitMilliseconds)) {
            $process.Kill(); $process.WaitForExit()
            throw 'Targeted DHCP renewal timed out.'
        }
        return [pscustomobject]@{ ExitCode=$process.ExitCode; Output=$stdout.Result; Error=$stderr.Result }
    } finally { $process.Dispose() }
}

function Restart-SharedDhcp {
    $service = Get-Service -Name 'VMnetDHCP'
    if ($service.Status -ne 'Running') { throw 'DHCP service is not running.' }
    try {
        $service.Stop(); $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(5))
        $service.Start(); $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(5))
    } finally {
        $service.Refresh()
        if ($service.Status -eq 'Stopped') { $service.Start() }
    }
}

function Read-ConfigBaseline {
    return Read-ValidBaseline (Join-Path $env:ProgramData 'VmnetSync\baseline.json')
}

function Save-ConfigBaseline($Snapshot) {
    Write-JsonAtomic (Join-Path $env:ProgramData 'VmnetSync\baseline.json') (New-ConfigBaseline $Snapshot)
}

function Update-EventAudit {
    . "$PSScriptRoot\Audit.ps1"
    Restore-ConfigAudit $ConfigDirectory
}

function Test-ConfigCurrent([string]$Fingerprint) {
    try { return (Read-NetworkFiles $ConfigDirectory).Fingerprint -eq $Fingerprint } catch { return $false }
}

function Write-RunResult($Result) {
    $Result | ConvertTo-Json -Depth 12 | Write-Output
    # A queued duplicate must not erase the useful result of the actual edit.
    if ($Mode -eq 'Repair' -and $Result.Status -ne 'NoChanges') { Write-JsonAtomic (Join-Path $env:ProgramData 'VmnetSync\last-result.json') $Result }
}

function Save-RepairSnapshot($Actual) {
    $script:beforeSnapshots[$Actual.Id] = $Actual
    Write-JsonAtomic (Join-Path $env:ProgramData 'VmnetSync\before-repair.json') @($script:beforeSnapshots.Values)
}

function Get-NetworkObservation($Desired) {
    $actual = $null
    if ($Desired.Disposition -eq 'Skipped') { $status='Skipped'; $reason=$Desired.Reason }
    elseif ($Desired.Disposition -eq 'Blocked') { $status='NeedsAttention'; $reason=$Desired.Reason }
    else {
        try {
            $actual = Get-ActualNetwork $Desired
            $decision = Get-SyncDecision $Desired $actual
            $status = if ($decision -eq 'Synced') { 'Synced' } else { 'NeedsAttention' }
            $reason = $decision
        } catch { $status='NeedsAttention'; $reason=$_.Exception.Message }
    }
    return [pscustomobject]@{ Id=$Desired.Id; Status=$status; Reason=$reason; Desired=$Desired; Actual=$actual }
}

function Invoke-Synchronization {
    if ($Mode -eq 'Check') {
        $snapshot = Read-NetworkFiles $ConfigDirectory
        $results = @($snapshot.Networks | Where-Object { $_.Disposition -ne 'Skipped' -or $_.Reason -ne 'Unused or bridged network' } | ForEach-Object { Get-NetworkObservation $_ })
        $bad = @($results | Where-Object { $_.Status -eq 'NeedsAttention' }).Count -gt 0
        $status = if ($bad) { 'NeedsAttention' } elseif (@($results | Where-Object { $_.Status -eq 'Synced' }).Count) { 'Synced' } else { 'Skipped' }
        Write-RunResult ([ordered]@{ Time=(Get-Date -Format o); Mode='Check'; Status=$status; Networks=$results; Changed=$false })
        if ($bad) { return 2 }; return 0
    }
    if (-not (Test-Administrator)) { throw 'Repair requires an elevated administrator terminal.' }
    $mutex = New-Object Threading.Mutex($false, 'Global\VmnetSync.Worker')
    $ownsMutex = $false
    try {
        try { $ownsMutex=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
        if (-not $ownsMutex) { Write-Output '{"Status":"Another worker is active"}'; return 0 }
        $baseline = if ($EventMode) { Read-ConfigBaseline } else { $null }
        if ($EventMode) { Update-EventAudit }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $states = @{}; $script:beforeSnapshots=@{}
        $changes = New-Object 'Collections.Generic.List[string]'
        $lastHash=''; $stable=0; $auditedHash=''; $dhcpRestarted=$false; $lastProblem='Configuration did not stabilize.'
        $snapshot=$null; $completed=$false; $acknowledge=$false; $work=@()
        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            try { $snapshot=Read-NetworkFiles $ConfigDirectory }
            catch { $lastProblem=$_.Exception.Message; $stable=0; Start-Sleep -Seconds 1; continue }
            if ($snapshot.Fingerprint -ne $lastHash) { $lastHash=$snapshot.Fingerprint; $stable=0 }
            $stable++
            if ($stable -lt 4) { Start-Sleep -Seconds 1; continue }
            if ($EventMode -and $auditedHash -ne $snapshot.Fingerprint) {
                Update-EventAudit; $auditedHash=$snapshot.Fingerprint
            }
            $work = if ($EventMode) { @(Get-ChangedNetworks $snapshot $baseline) } else { @($snapshot.Networks) }
            # A network touched earlier in this run must still be checked if the
            # editor reverted it to the baseline while a renewal was in flight.
            foreach ($id in @($states.Keys)) {
                if (@($work | Where-Object { $_.Id -eq $id }).Count -eq 0) {
                    $current = @($snapshot.Networks | Where-Object { $_.Id -eq $id })
                    if ($current.Count) { $work += $current[0] }
                    else { $work += [pscustomobject]@{ Id=$id; Kind='None'; Disposition='Skipped'; Reason='Network removed from VMware'; Fingerprint='Removed' } }
                }
            }
            $refresh=$false
            foreach ($desired in $work) {
                if (-not $states.ContainsKey($desired.Id) -or $states[$desired.Id].Fingerprint -ne $desired.Fingerprint) {
                    $states[$desired.Id]=[pscustomobject]@{ Fingerprint=$desired.Fingerprint; Attempt=0; Good=0; Done=$false; Result=$null }
                }
                $state=$states[$desired.Id]
                $observation=Get-NetworkObservation $desired; $state.Result=$observation
                if ($desired.Disposition -ne 'Ready') { $state.Done=$true; continue }
                if ($observation.Status -eq 'Synced') { $state.Good++; $state.Done=($state.Good -ge 3); continue }
                $state.Good=0; $state.Done=$false
                $decision=$observation.Reason; $lastProblem=$decision
                if ($decision -ne 'Repair' -or $state.Attempt -ge 2) { continue }
                $remaining=[int](($TimeoutSeconds-$timer.Elapsed.TotalSeconds)*1000)
                if ($remaining -lt 5000) { continue }
                if (-not (Test-ConfigCurrent $snapshot.Fingerprint)) { $refresh=$true; break }
                $live=Get-ActualNetwork $desired
                if ((Get-SyncDecision $desired $live) -ne 'Repair' -or -not $live.ServicesRunning) { continue }
                if ($state.Attempt -eq 0) { Save-RepairSnapshot $live }
                $state.Attempt++
                try {
                    if ($state.Attempt -eq 2 -and -not $dhcpRestarted) {
                        if ($remaining -lt 16000) { continue }
                        # The service is shared. Never restart it more than once
                        # per run, even when multiple networks need a second try.
                        $dhcpRestarted=$true
                        Restart-SharedDhcp
                        $changes.Add('Restarted shared VMware DHCP service')
                        foreach ($other in $states.Values) { $other.Good=0; $other.Done=$false }
                    }
                    if (-not (Test-ConfigCurrent $snapshot.Fingerprint)) { $refresh=$true; break }
                    # Restart/Apply can replace an adapter: validate its identity again.
                    $fresh=Get-ActualNetwork $desired
                    if ((Get-SyncDecision $desired $fresh) -ne 'Repair' -or -not $fresh.ServicesRunning) { continue }
                    $remaining=[math]::Min(15000,[int](($TimeoutSeconds-$timer.Elapsed.TotalSeconds)*1000))
                    if ($remaining -lt 1000) { continue }
                    $renewal=Invoke-AdapterRenew $fresh.Name $remaining -Rebind:($state.Attempt -eq 2)
                    $detail=if ($state.Attempt -eq 2) { ' (released stale lease first)' } else { '' }
                    $changes.Add("$($desired.Id): renewed DHCP on $($fresh.Name)$detail; exit code $($renewal.ExitCode)")
                } catch { $state.Result.Reason=$_.Exception.Message; $lastProblem=$_.Exception.Message }
            }
            if ($refresh) { continue }
            if (@($states.Values | Where-Object { -not $_.Done }).Count -eq 0) {
                if (-not (Test-ConfigCurrent $snapshot.Fingerprint)) { continue }
                $completed=$true; $acknowledge=$true; break
            }
            Start-Sleep -Seconds 1
        }
        # Acknowledge a stable observed edit, including a failed one. An unrelated
        # future edit must not silently retry a previously failed, unchanged VMnet.
        if (-not $completed -and $stable -ge 4 -and $null -ne $snapshot) {
            try { $acknowledge=((Read-NetworkFiles $ConfigDirectory).Fingerprint -eq $snapshot.Fingerprint) } catch { }
        }
        $results=@($states.Keys | Sort-Object | ForEach-Object { $state=$states[$_]; if ($null -ne $state.Result) { if (-not $state.Done -and $state.Result.Status -eq 'Synced') { $state.Result.Status='NeedsAttention'; $state.Result.Reason='Timed out before three successful observations' }; $state.Result } })
        $bad=-not $completed -or @($results | Where-Object { $_.Status -eq 'NeedsAttention' }).Count -gt 0
        $reasons=@($results | Where-Object { $_.Status -eq 'NeedsAttention' } | ForEach-Object { "$($_.Id): $($_.Reason)" })
        if ($reasons.Count) { $lastProblem=$reasons -join '; ' }
        $status=if ($bad) { 'NeedsAttention' } elseif ($results.Count -eq 0) { 'NoChanges' } elseif (@($results | Where-Object { $_.Status -eq 'Synced' }).Count) { 'Synced' } else { 'Skipped' }
        if ($acknowledge) { Save-ConfigBaseline $snapshot }
        Write-RunResult ([ordered]@{ Time=(Get-Date -Format o); Mode='Repair'; Status=$status; Reason=$(if ($bad) { $lastProblem } else { '' }); Networks=$results; Changes=@($changes.ToArray()); ElapsedSeconds=[math]::Round($timer.Elapsed.TotalSeconds,2) })
        if ($bad) { return 2 }; return 0
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { $code=Invoke-Synchronization; $numbers=@($code | Where-Object { $_ -is [int] }); $code | Where-Object { $_ -isnot [int] } | Write-Output; exit $numbers[-1] }
    catch {
        try { Write-RunResult ([ordered]@{ Time=(Get-Date -Format o); Mode=$Mode; Status='Error'; Reason=$_.Exception.Message }) } catch { }
        Write-Error $_ -ErrorAction Continue; exit 1
    }
}
