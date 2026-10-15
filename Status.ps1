#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Json)
$ErrorActionPreference = 'Stop'
$installation = Join-Path $env:ProgramFiles 'Vmnet8Sync\installation.json'
$resultFile = Join-Path $env:ProgramData 'Vmnet8Sync\last-result.json'
$status = [ordered]@{
    Installed = (Test-Path -LiteralPath $installation)
    Version = $null; TaskState = 'Not registered'; RunningInstances = $null
    EventOnly = $null; TaskInspectionError = $null; LastResult = $null
}
if ($status.Installed) {
    $manifest = [IO.File]::ReadAllText($installation) | ConvertFrom-Json
    $status.Version = if ($manifest.PSObject.Properties['ProductVersion']) { $manifest.ProductVersion } else { 'prototype' }
}
try {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $task = $scheduler.GetFolder('\').GetTask('Vmnet8Sync-AfterConfigWrite')
    $states = @('Unknown', 'Disabled', 'Queued', 'Ready', 'Running')
    $status.TaskState = $states[[int]$task.State]
    $status.RunningInstances = $task.GetInstances(0).Count
    $definition = $task.Definition
    $status.EventOnly = ($definition.Triggers.Count -eq 1 -and $definition.Triggers.Item(1).Type -eq 0 -and
        -not $definition.Settings.StartWhenAvailable -and -not $definition.Settings.WakeToRun -and -not $definition.Settings.AllowDemandStart)
} catch {
    $status.TaskInspectionError = $_.Exception.Message
    $status.TaskState = 'Unavailable (not registered or access denied)'
}
if (Test-Path -LiteralPath $resultFile) {
    try { $status.LastResult = [IO.File]::ReadAllText($resultFile) | ConvertFrom-Json }
    catch { $status.LastResult = [pscustomobject]@{ Status='Unreadable'; Reason=$_.Exception.Message } }
}
if ($Json) { [pscustomobject]$status | ConvertTo-Json -Depth 10; return }
Write-Host 'VMnet8 Sync' -ForegroundColor Cyan
Write-Host "Installed: $($status.Installed)    Version: $($status.Version)"
Write-Host "Task: $($status.TaskState)    Running workers: $($status.RunningInstances)"
Write-Host "Event-only configuration: $($status.EventOnly)"
if ($null -ne $status.TaskInspectionError) { Write-Host "Task inspection: $($status.TaskInspectionError)" -ForegroundColor Yellow }
if ($null -eq $status.LastResult) {
    Write-Host 'No result yet. This is normal before the first network-configuration change.'
} else {
    Write-Host "`nLast automatic check:"
    $status.LastResult | ConvertTo-Json -Depth 8 | Write-Host
}
Write-Host "`nReady means Windows is waiting for a configuration-write event; it is not a resident worker."
