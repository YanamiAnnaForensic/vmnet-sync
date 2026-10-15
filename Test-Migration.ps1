#Requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Audit.ps1"
. "$PSScriptRoot\Setup.Common.ps1"
$migrationTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('vmnet-migration-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -Path $migrationTestRoot -ItemType Directory)
$script:migrationTestTask=[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$true}}
$script:migrationStarts=0
function Assert-ManagedDirectory($Path) {
    if (-not ([IO.Path]::GetFullPath($Path)).StartsWith($migrationTestRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Test escaped its directory.' }
}
function Assert-InstallManifest($Manifest,$ConfigDirectory,$ExpectedTaskName) {
    if ($Manifest.TaskName -ne $ExpectedTaskName -or $Manifest.ConfigDirectory -ne $ConfigDirectory) { throw 'Invalid test manifest.' }
}
function Get-ScheduledTask { return $script:migrationTestTask }
function Export-ScheduledTask { return '<legacy-task/>' }
function Disable-ScheduledTask { $script:migrationTestTask.Settings.Enabled=$false }
function Enable-ScheduledTask { $script:migrationTestTask.Settings.Enabled=$true }
function Wait-WorkerExit { }
function Register-ScheduledTask { $script:migrationTestTask=[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$false}} }
function Unregister-ScheduledTask { $script:migrationTestTask=$null }
function Start-ScheduledTask { $script:migrationStarts++; throw 'Migration started a worker.' }
function Assert-Migration($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
try {
    $old=Join-Path $migrationTestRoot 'old-program'; $oldData=Join-Path $migrationTestRoot 'old-data'
    $new=Join-Path $migrationTestRoot 'new-program'; $newData=Join-Path $migrationTestRoot 'new-data'
    [void](New-Item -Path $old,$oldData -ItemType Directory)
    $original='{"Version":1,"TaskName":"Vmnet8Sync-AfterConfigWrite","ConfigDirectory":"fixture","AuditEntries":[]}'
    [IO.File]::WriteAllText((Join-Path $old 'installation.json'),$original)
    [IO.File]::WriteAllText((Join-Path $oldData 'last-result.json'),'retained')
    $migration=Move-LegacyInstallation 'fixture' $new $newData $old $oldData
    Assert-Migration (-not (Test-Path -LiteralPath $old)) 'Old program directory remained.'
    Assert-Migration (([IO.File]::ReadAllText((Join-Path $new 'installation.json')) | ConvertFrom-Json).TaskName -eq 'VmnetSync-AfterConfigWrite') 'Task name did not migrate.'
    Assert-Migration ([IO.File]::ReadAllText((Join-Path $newData 'last-result.json')) -eq 'retained') 'Lost diagnostics.'
    Assert-Migration (-not $script:migrationTestTask.Settings.Enabled) 'Legacy task remained enabled.'
    Write-Output 'PASS Legacy directories, manifest and diagnostics migrate without starting worker'
    Complete-LegacyMigration $migration
    Assert-Migration ($null -eq $script:migrationTestTask) 'Legacy task was not removed.'
    Undo-LegacyMigration $migration
    Assert-Migration ([IO.File]::ReadAllText((Join-Path $old 'installation.json')) -ceq $original) 'Original manifest bytes were not restored.'
    Assert-Migration ($script:migrationTestTask.Settings.Enabled) 'Legacy task not restored after failure.'
    Assert-Migration (-not (Test-Path -LiteralPath $new)) 'Rollback left new program directory.'
    Assert-Migration ([IO.File]::ReadAllText((Join-Path $oldData 'last-result.json')) -eq 'retained') 'Rollback lost diagnostics.'
    Write-Output 'PASS Rollback restores original directories, manifest and enabled task'
    [void](New-Item -Path $new -ItemType Directory)
    $rejected=$false
    try { Move-LegacyInstallation 'fixture' $new $newData $old $oldData } catch { $rejected=$true }
    Assert-Migration $rejected 'Conflicting installations were accepted.'
    Assert-Migration ($script:migrationTestTask.Settings.Enabled) 'Conflict changed legacy task.'
    Assert-Migration ($script:migrationStarts -eq 0) 'Migration started a worker.'
    Write-Output 'PASS Conflicting installations are rejected before mutation'
    $noDataOld=Join-Path $migrationTestRoot 'missing-data-old-program'
    $noDataNew=Join-Path $migrationTestRoot 'missing-data-new-program'
    $noDataLegacy=Join-Path $migrationTestRoot 'missing-legacy-data'
    $noDataNewData=Join-Path $migrationTestRoot 'newly-created-data'
    [void](New-Item -Path $noDataOld -ItemType Directory)
    [IO.File]::WriteAllText((Join-Path $noDataOld 'installation.json'),$original)
    $migration=Move-LegacyInstallation 'fixture' $noDataNew $noDataNewData $noDataOld $noDataLegacy
    [void](New-Item -Path $noDataNewData -ItemType Directory)
    Undo-LegacyMigration $migration
    Assert-Migration (-not (Test-Path -LiteralPath $noDataNewData)) 'Rollback left a new empty data directory.'
    $retry=Move-LegacyInstallation 'fixture' $noDataNew $noDataNewData $noDataOld $noDataLegacy
    Undo-LegacyMigration $retry
    Assert-Migration ($script:migrationTestTask.Settings.Enabled) 'Retry did not restore the legacy task.'
    Write-Output 'PASS Missing legacy diagnostics do not leave a directory that prevents retry after rollback'
} finally {
    $resolved=[IO.Path]::GetFullPath($migrationTestRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'vmnet-migration-*') { throw 'Unexpected cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
