#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Test.ps1"
. "$PSScriptRoot\Sync.ps1" -Mode Repair -TimeoutSeconds 15

# Mock all host inspection/mutation and output persistence. The real worker's
# debounce, fresh-read guard, retry decisions and exit path run unchanged.
function Test-Administrator { return $true }
function Save-RepairSnapshot($Actual) { $script:snapshots++ }
function Write-RunResult($Result) { $script:lastResult = $Result }
function Get-ActualNetwork($Desired) {
    $actual = New-Actual
    $actual | Add-Member Name 'Renamed VMnet8'
    if (-not $script:renewed) { $actual.Addresses[0].IPAddress = '192.168.56.1'; $actual.DirectRoute = $false }
    if ($script:forceStopped) { $actual.ServicesRunning = $false }
    return $actual
}
function Read-NetworkFiles([string]$Directory) {
    $script:reads++
    if ($script:changeDuringRepair -and $script:reads -eq 5) {
        # Configuration changes between the stable observation and mutation.
        $script:desired.Fingerprint = 'NEW-CONFIGURATION'
        $script:renewed = $true
    }
    # Return a detached snapshot, just like the production reader.
    return $script:desired | ConvertTo-Json | ConvertFrom-Json
}
function Invoke-AdapterRenew([string]$Alias, [int]$LimitMilliseconds) {
    Assert-Equal 'Renamed VMnet8' $Alias
    $script:renewals++
    $script:renewed = $true
    return [pscustomobject]@{ ExitCode=0; Output=''; Error='' }
}
function Reset-Scenario {
    $script:desired = Read-DesiredNetwork $nat $dhcp
    $script:reads = 0; $script:renewals = 0; $script:snapshots = 0
    $script:renewed = $false; $script:forceStopped = $false
    $script:changeDuringRepair = $false; $script:lastResult = $null
}
Test-Case 'Worker renews only the target adapter, verifies state, and exits' {
    Reset-Scenario
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 1 $script:renewals
    Assert-Equal 1 $script:snapshots
    Assert-Equal 'Synced' $script:lastResult.Status
}
Test-Case 'Worker exits without mutation when already synchronized' {
    Reset-Scenario; $script:renewed=$true
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 0 $script:renewals
    Assert-Equal 0 $script:snapshots
}
Test-Case 'A configuration change before mutation cancels the obsolete repair' {
    Reset-Scenario; $script:changeDuringRepair=$true
    Assert-Equal 0 (Invoke-Synchronization)
    Assert-Equal 0 $script:renewals
    Assert-Equal 0 $script:snapshots
}
Test-Case 'Stopped VMware services cause bounded exit without starting disabled services' {
    Reset-Scenario; $script:forceStopped=$true
    Assert-Equal 2 (Invoke-Synchronization)
    Assert-Equal 0 $script:renewals
    Assert-Equal 'NeedsAttention' $script:lastResult.Status
    if ($script:lastResult.ElapsedSeconds -gt 18) { throw 'Worker exceeded the test timeout tolerance.' }
}
Write-Output "Passed $script:passed tests including worker lifecycle. Host mutation and persistence were mocked."
