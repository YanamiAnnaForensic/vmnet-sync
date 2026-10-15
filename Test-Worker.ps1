#Requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Test-MultiNetwork.ps1"
. "$PSScriptRoot\Sync.ps1" -Mode Repair -TimeoutSeconds 15 -EventMode

# All host mutations, inspection and persistence are mocked. The worker uses
# its production debounce, per-network selection, retry and exit logic.
function Test-Administrator { return $true }
function Update-EventAudit { $script:audits++ }
function Save-RepairSnapshot($Actual) { $script:snapshots++ }
function Write-RunResult($Result) { $script:lastResult=$Result }
function Read-ConfigBaseline { return $script:baseline }
function Save-ConfigBaseline($Snapshot) { $script:baseline=New-ConfigBaseline $Snapshot; $script:saves++ }
function Get-ActualNetwork($Desired) {
    $script:inspected.Add($Desired.Id)
    $actual=[pscustomobject]@{
        Id=$Desired.Id; AdapterCount=1; Mac=$Desired.HostMac; Status='Up'; DhcpEnabled=$true
        Name=('Renamed '+$Desired.Id); Index=8; DirectRoute=$true; DefaultRoute=$false; ServicesRunning=$true
        Addresses=@([pscustomobject]@{IPAddress=$Desired.HostIP; PrefixLength=$Desired.PrefixLength; AddressState='Preferred'})
    }
    if (-not $script:renewed.ContainsKey($Desired.Id)) { $actual.Addresses[0].IPAddress='10.0.0.1'; $actual.DirectRoute=$false }
    if ($script:forceStopped) { $actual.ServicesRunning=$false }
    if ($script:missing -eq $Desired.Id) { $actual.AdapterCount=0 }
    if ($script:disabled -eq $Desired.Id) { $actual.Status='Disabled' }
    if ($script:static -eq $Desired.Id) { $actual.DhcpEnabled=$false }
    if ($script:wrongMac -eq $Desired.Id) { $actual.Mac='000000000000' }
    return $actual
}
function Read-NetworkFiles([string]$Directory) {
    $script:reads++
    if ($script:changeDuringRepair -and $script:reads -eq 5) {
        $script:desired.Networks[0].Fingerprint=Get-TextHash 'NEW-CONFIGURATION'
        $script:desired.Fingerprint=Get-TextHash ($script:desired.Networks | ConvertTo-Json -Depth 8)
        $script:renewed['VMnet1']=$true
    }
    return $script:desired | ConvertTo-Json -Depth 8 | ConvertFrom-Json
}
function Invoke-AdapterRenew([string]$Alias, [int]$LimitMilliseconds) {
    $id=$Alias.Replace('Renamed ','')
    $script:renewals.Add($id)
    if (-not $script:needsRestart -or $script:restarts -gt 0) { $script:renewed[$id]=$true }
    if ($script:addDuringRenew -and $id -eq 'VMnet1') {
        $new=Read-DesiredNetwork $nat $dhcp
        $script:desired.Networks += $new
        $script:desired.Fingerprint=Get-TextHash ($script:desired.Networks | ConvertTo-Json -Depth 8)
        $script:addDuringRenew=$false
    }
    return [pscustomobject]@{ExitCode=0; Output=''; Error=''}
}
function Restart-SharedDhcp { $script:restarts++ }
function Reset-Scenario {
    $script:desired=[pscustomobject]@{Networks=@((Read-DesiredNetwork '' $dhcp 'VMnet1' $false), (Read-DesiredNetwork $nat $dhcp)); Fingerprint=(Get-TextHash 'current')}
    $script:baseline=[pscustomobject]@{Version=2;Networks=@()}
    $script:reads=0; $script:snapshots=0; $script:saves=0; $script:audits=0; $script:restarts=0
    $script:renewals=New-Object 'Collections.Generic.List[string]'
    $script:inspected=New-Object 'Collections.Generic.List[string]'
    $script:renewed=@{}; $script:forceStopped=$false; $script:needsRestart=$false
    $script:missing=''; $script:disabled=''; $script:static=''; $script:wrongMac=''
    $script:changeDuringRepair=$false; $script:addDuringRenew=$false; $script:lastResult=$null
}
Test-Case 'VMnet1-only edit never inspects or renews unchanged VMnet8, even if its live lease is stale' {
    Reset-Scenario
    $script:baseline=New-ConfigBaseline $script:desired
    $script:baseline.Networks[0].Fingerprint=Get-TextHash 'old-host-only'
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 'VMnet1' ($script:renewals -join ',')
    Assert-Equal $false ($script:inspected.Contains('VMnet8'))
    Assert-Equal 'Synced' $script:lastResult.Status
}
Test-Case 'Two changed networks renew independently and verify before exit' {
    Reset-Scenario
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 'VMnet1,VMnet8' ($script:renewals -join ',')
    Assert-Equal 2 $script:snapshots
    Assert-Equal 2 $script:lastResult.Networks.Count
}
Test-Case 'Queued duplicate write event exits without inspecting or mutating adapters' {
    Reset-Scenario; $script:baseline=New-ConfigBaseline $script:desired
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 0 $script:renewals.Count; Assert-Equal 0 $script:inspected.Count
    Assert-Equal 'NoChanges' $script:lastResult.Status
}
Test-Case 'Already synchronized changed networks are verified without repair' {
    Reset-Scenario; $script:renewed=@{VMnet1=$true;VMnet8=$true}
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 0 $script:renewals.Count; Assert-Equal 0 $script:snapshots
}
Test-Case 'Configuration change before mutation cancels an obsolete repair' {
    Reset-Scenario; $script:changeDuringRepair=$true; $script:renewed['VMnet8']=$true
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 0 $script:renewals.Count; Assert-Equal 0 $script:snapshots
}
Test-Case 'A network added during a renewal is picked up in the same run' {
    Reset-Scenario; $script:desired.Networks=@($script:desired.Networks[0]); $script:addDuringRenew=$true
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 'VMnet1,VMnet8' ($script:renewals -join ',')
}
Test-Case 'Shared DHCP restarts at most once when two networks require retry' {
    $TimeoutSeconds=25
    Reset-Scenario; $script:needsRestart=$true
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 1 $script:restarts
    Assert-Equal 4 $script:renewals.Count
}
Test-Case 'Invalid sibling is reported while valid changed network still synchronizes' {
    Reset-Scenario; $script:desired.Networks[1].Disposition='Blocked'; $script:desired.Networks[1].Reason='NAT mismatch'
    Assert-Equal 2 (Invoke-Synchronization)
    Assert-Equal 'VMnet1' ($script:renewals -join ',')
    Assert-Equal 'Synced' $script:lastResult.Networks[0].Status
    Assert-Equal 'NeedsAttention' $script:lastResult.Networks[1].Status
}
Test-Case 'Disabled host connection and DHCP-off networks exit as skipped without inspection' {
    Reset-Scenario
    foreach ($network in $script:desired.Networks) { $network.Disposition='Skipped'; $network.Reason='Host connection or DHCP disabled' }
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 0 $script:inspected.Count; Assert-Equal 'Skipped' $script:lastResult.Status
}
Test-Case 'Missing, disabled, static or wrong-MAC adapters never reach the renewal API' {
    Reset-Scenario
    foreach ($scenario in @('missing','disabled','static','wrongMac')) {
        Set-Variable -Name $scenario -Scope Script -Value 'VMnet1'
        $desired=$script:desired.Networks[0]
        Assert-Equal 'NeedsAttention' (Get-NetworkObservation $desired).Status
        Assert-Equal $true (Get-SyncDecision $desired (Get-ActualNetwork $desired)).StartsWith('Blocked:')
        Set-Variable -Name $scenario -Scope Script -Value ''
    }
    Assert-Equal 0 $script:renewals.Count
}
Test-Case 'Stopped services cause bounded exit; an unrelated future edit does not retry the failed network' {
    Reset-Scenario; $script:forceStopped=$true
    Assert-Equal 2 (Invoke-Synchronization)
    Assert-Equal 0 $script:renewals.Count; Assert-Equal 'NeedsAttention' $script:lastResult.Status
    if ($script:lastResult.ElapsedSeconds -gt 18) { throw 'Worker exceeded its test timeout tolerance.' }
    # The stable edit is acknowledged even on failure, avoiding surprise repairs.
    $script:forceStopped=$false; $script:reads=0; $script:inspected.Clear()
    $script:desired.Networks[0].Fingerprint=Get-TextHash 'a later host-only edit'
    $script:desired.Fingerprint=Get-TextHash 'a later snapshot'
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 'VMnet1' ($script:renewals -join ',')
    Assert-Equal $false ($script:inspected.Contains('VMnet8'))
}
Test-Case 'Host-only live observation does not depend on NAT service status' {
    # Use the real observation function, mocking only the Windows APIs.
    $production=${function:Get-ActualNetwork}
    try {
        . "$PSScriptRoot\Sync.ps1" -Mode Repair -TimeoutSeconds 15 -EventMode
        function Get-NetAdapter { [pscustomobject]@{InterfaceDescription='VMware Virtual Ethernet Adapter for VMnet1';Name='HostOnly';ifIndex=9;MacAddress='00-50-56-C0-00-01';Status='Up'} }
        function Get-NetIPAddress { [pscustomobject]@{IPAddress='192.168.93.1';PrefixLength=24;AddressState='Preferred';PrefixOrigin='Dhcp'} }
        function Get-NetIPInterface { [pscustomobject]@{Dhcp='Enabled'} }
        function Get-NetRoute { [pscustomobject]@{DestinationPrefix='192.168.93.0/24';NextHop='0.0.0.0'} }
        function Get-Service($Name) {
            foreach ($item in $Name) { [pscustomobject]@{Name=$item;Status=$(if ($item -eq 'VMnetDHCP') {'Running'} else {'Stopped'})} }
        }
        $hostOnly=Read-DesiredNetwork '' $dhcp 'VMnet1' $false
        Assert-Equal 'Synced' (Get-SyncDecision $hostOnly (Get-ActualNetwork $hostOnly))
    } finally { ${function:Get-ActualNetwork}=$production }
}
Write-Output "Passed $script:passed tests including multi-network worker lifecycle. Host mutation and persistence were mocked."
