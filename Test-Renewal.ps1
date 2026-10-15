#Requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.ps1"
$script:renewalCalls=@();$script:releaseFails=$false
function Invoke-TargetIpConfig($Alias,$Operation,$LimitMilliseconds) {
    $script:renewalCalls+=@{Alias=$Alias;Operation=$Operation;Limit=$LimitMilliseconds}
    if ($Operation -eq 'release' -and $script:releaseFails) { throw 'Simulated release timeout' }
    return [pscustomobject]@{ExitCode=0;Output=$Operation;Error=''}
}
$testAlias='Renamed VMware Adapter'
[void](Invoke-AdapterRenew $testAlias 15000)
if (($script:renewalCalls.Operation -join ',') -ne 'renew') { throw 'Initial renewal unexpectedly released the lease.' }
Write-Output 'PASS First attempt renews only the selected adapter'
$script:renewalCalls=@()
[void](Invoke-AdapterRenew $testAlias 15000 -Rebind)
if (($script:renewalCalls.Operation -join ',') -ne 'release,renew' -or @($script:renewalCalls | Where-Object Alias -ne $testAlias).Count) { throw 'Rebinding did not release and renew exactly the selected adapter.' }
if ($script:renewalCalls[0].Limit -gt 5000 -or $script:renewalCalls[1].Limit -gt 15000) { throw 'Unexpected command time budget.' }
Write-Output 'PASS Stale lease retry releases then renews the same adapter with bounded commands'
$script:renewalCalls=@();$script:releaseFails=$true
[void](Invoke-AdapterRenew $testAlias 15000 -Rebind)
if (($script:renewalCalls.Operation -join ',') -ne 'release,renew') { throw 'Release failure suppressed the recovery renewal.' }
Write-Output 'PASS Release timeout still attempts renewal to recover the DHCP address'
