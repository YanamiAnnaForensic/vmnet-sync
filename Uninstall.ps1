#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Audit.ps1"
. "$PSScriptRoot\Setup.Common.ps1"
$destination = Join-Path $env:ProgramFiles 'VmnetSync'
$manifestPath = Join-Path $destination 'installation.json'
$mutex = New-Object Threading.Mutex($false, 'Global\VmnetSync.Setup')
$ownsMutex = $false
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another install or uninstall is running.' }
    Assert-ManagedDirectory $destination
    if (-not (Test-Path -LiteralPath $manifestPath)) { Write-Output 'VMnet Sync is not installed.'; return }
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    Assert-InstallManifest $manifest (Join-Path $env:ProgramData 'VMware')
    Initialize-AuditNative
    $task = Get-ScheduledTask -TaskName $manifest.TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Disable-ScheduledTask -TaskName $manifest.TaskName | Out-Null
        Wait-WorkerExit $manifest.TaskName
    }
    # Keep the disabled task and manifest if cleanup fails so uninstall can be retried.
    foreach ($entry in $manifest.AuditEntries) {
        Remove-AddedConfigAudit $entry $manifest.ConfigDirectory
    }
    if ($task) { Unregister-ScheduledTask -TaskName $manifest.TaskName -Confirm:$false }
    foreach ($name in @('Core.ps1','Sync.ps1','Audit.ps1','Setup.Common.ps1','Status.ps1','VERSION','task.xml','installation.json','Uninstall.ps1')) {
        $path = Join-Path $destination $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path }
    }
    if (@(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0) { Remove-Item -LiteralPath $destination }
    Write-Output 'Removed the automatic task, product files and tool-added audit rules.'
    Write-Output "Last diagnostics are retained in $env:ProgramData\VmnetSync. File System and Registry audit policies are preserved for other tools."
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
