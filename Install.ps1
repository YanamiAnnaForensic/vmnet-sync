#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Elevate)
$ErrorActionPreference = 'Stop'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    if ($Elevate) {
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"') -Wait -PassThru
        exit $process.ExitCode
    }
    throw 'Run Install.cmd, or run this script from an administrator terminal.'
}
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell (Install.cmd selects it automatically).' }
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Audit.ps1"
. "$PSScriptRoot\Setup.Common.ps1"
$config = Join-Path $env:ProgramData 'VMware'
$destination = Join-Path $env:ProgramFiles 'Vmnet8Sync'
$dataDirectory = Join-Path $env:ProgramData 'Vmnet8Sync'
$taskName = 'Vmnet8Sync-AfterConfigWrite'
$manifestPath = Join-Path $destination 'installation.json'
$runtimeFiles = @('Core.ps1','Sync.ps1','Audit.ps1','Setup.Common.ps1','Uninstall.ps1','Status.ps1','VERSION')
$savedFiles = @{}
$oldTaskXml = $null
$oldTaskEnabled = $false
$newTaskRegistered = $false
$taskDisabled = $false
$auditChanged = $false
$policyChanged = $false
$oldFlags = $null
$oldRegistryFlags = $null
$registryPolicyChanged = $false
$savedBaseline = $null
$entries = @()
$newRights = @()
$filesChanged = $false
$setupMutex = New-Object Threading.Mutex($false, 'Global\Vmnet8Sync.Setup')
$ownsMutex = $false
try {
    try { $ownsMutex = $setupMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Another install or uninstall is running.' }
    $initialSnapshot = Read-NetworkFiles $config
    $editors = @(Get-NetworkEditors)
    foreach ($name in $runtimeFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) { throw "Package is incomplete: $name. Extract the full ZIP first." }
    }
    $version = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid package version.' }
    foreach ($directory in @($destination, $dataDirectory)) { Assert-ManagedDirectory $directory }
    $previous = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $previous = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        Assert-InstallManifest $previous $config
    } elseif (Test-Path -LiteralPath $destination) {
        if (@(Get-ChildItem -LiteralPath $destination -Force).Count -gt 0) { throw "Unrecognized directory: $destination. Review its contents before installing." }
    }
    $oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($oldTask -and $null -eq $previous) { throw "Task already exists without a matching manifest: $taskName" }
    Initialize-AuditNative
    $oldFlags = [Vmnet8Sync.AuditNative]::GetFlags()
    $oldRegistryFlags = [Vmnet8Sync.AuditNative]::GetRegistryFlags()
    foreach ($target in @(Get-ConfigAuditTargets $config)) {
        $rule = New-ConfigAuditRule $target
        $existingRights = 0
        if (Test-Path -LiteralPath $target.Path) { $existingRights = Get-ExistingAuditRights (Get-ConfigAuditAcl $target) $rule }
        $added = [int]$target.Rights -band (-bnot $existingRights)
        $previousAdded = 0
        if ($null -ne $previous) {
            $oldEntries = @($previous.AuditEntries | Where-Object { $_.Path -ieq $target.Path })
            if ($oldEntries.Count -eq 1) { $previousAdded = [int]$oldEntries[0].AddedRights }
        }
        $newRights += [pscustomobject]@{ Path=$target.Path; AddedRights=$added }
        $entries += [pscustomobject]@{ Path=$target.Path; AddedRights=($previousAdded -bor $added) }
    }
    if ($oldTask) {
        $oldTaskXml = Export-ScheduledTask -TaskName $taskName
        $oldTaskEnabled = $oldTask.Settings.Enabled
        Disable-ScheduledTask -TaskName $taskName | Out-Null
        $taskDisabled = $true
        Wait-WorkerExit $taskName
    }
    New-ManagedDirectory $destination
    New-ManagedDirectory $dataDirectory
    $baselinePath = Join-Path $dataDirectory 'baseline.json'
    if (Test-Path -LiteralPath $baselinePath) { $savedBaseline = [IO.File]::ReadAllBytes($baselinePath) }
    foreach ($name in ($runtimeFiles + @('installation.json','task.xml'))) {
        $path = Join-Path $destination $name
        $savedFiles[$name] = if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllBytes($path) } else { $null }
    }
    $filesChanged = $true
    foreach ($name in $runtimeFiles) {
        [IO.File]::WriteAllBytes((Join-Path $destination $name), [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $name)))
    }
    $originalFlags = if ($null -ne $previous) { $previous.OriginalAuditFlags } else { $oldFlags }
    $originalRegistryFlags = if ($null -ne $previous -and $previous.PSObject.Properties['OriginalRegistryAuditFlags']) { $previous.OriginalRegistryAuditFlags } else { $oldRegistryFlags }
    $manifest = [ordered]@{ Version=2; ProductVersion=$version; Installed=(Get-Date -Format o); ConfigDirectory=$config; TaskName=$taskName; OriginalAuditFlags=$originalFlags; OriginalRegistryAuditFlags=$originalRegistryFlags; AuditEntries=$entries }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5))
    [Vmnet8Sync.AuditNative]::SetFlags(($oldFlags -band 3) -bor 1)
    $policyChanged = $true
    if (([Vmnet8Sync.AuditNative]::GetFlags() -band 1) -eq 0) { throw 'File System success auditing did not become active; check group policy.' }
    [Vmnet8Sync.AuditNative]::SetRegistryFlags(($oldRegistryFlags -band 3) -bor 1)
    $registryPolicyChanged = $true
    if (([Vmnet8Sync.AuditNative]::GetRegistryFlags() -band 1) -eq 0) { throw 'Registry success auditing did not become active; check group policy.' }
    $auditChanged = $true
    Restore-ConfigAudit $config
    $snapshot = Read-NetworkFiles $config
    if ($snapshot.Fingerprint -ne $initialSnapshot.Fingerprint) { throw 'VMware configuration changed during installation. Finish applying network settings, then run setup again.' }
    # Snapshot only: setup does not inspect or repair any live adapter.
    # Preserve a v2 baseline during upgrades, including changes not processed yet.
    $baselineValid=$false
    if ($null -ne $savedBaseline) { try { [void](Read-ValidBaseline $baselinePath); $baselineValid=$true } catch { } }
    if ($null -eq $previous -or $previous.Version -eq 1 -or -not $baselineValid) { Write-JsonAtomic $baselinePath (New-ConfigBaseline $snapshot) }
    $xml = New-SyncTaskXml $config (Join-Path $destination 'Sync.ps1') $editors
    [IO.File]::WriteAllText((Join-Path $destination 'task.xml'), $xml, [Text.Encoding]::Unicode)
    [void](Register-ScheduledTask -TaskName $taskName -Xml $xml -Force)
    $newTaskRegistered = $true
    Write-Output "VMnet8 Sync $version installed. Waiting for a VMware configuration-write event."
    Write-Output 'No worker was started by installation. Use Status.cmd to inspect the task.'
} catch {
    $failure = $_
    if ($newTaskRegistered) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Continue }
    if ($auditChanged) {
        foreach ($entry in $newRights) {
            try { Remove-AddedConfigAudit $entry $config } catch { Write-Warning "Audit rollback: $($_.Exception.Message)" }
        }
    }
    if ($policyChanged) { [Vmnet8Sync.AuditNative]::SetFlags($oldFlags) }
    if ($registryPolicyChanged) { [Vmnet8Sync.AuditNative]::SetRegistryFlags($oldRegistryFlags) }
    if ($filesChanged) {
        if ($null -ne $savedBaseline) { [IO.File]::WriteAllBytes($baselinePath, $savedBaseline) }
        elseif (Test-Path -LiteralPath $baselinePath) { Remove-Item -LiteralPath $baselinePath }
        foreach ($name in $savedFiles.Keys) {
            $path = Join-Path $destination $name
            if ($null -eq $savedFiles[$name]) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path } }
            else { [IO.File]::WriteAllBytes($path, $savedFiles[$name]) }
        }
    }
    if ($taskDisabled) {
        if ($null -ne $oldTaskXml -and $newTaskRegistered) { [void](Register-ScheduledTask -TaskName $taskName -Xml $oldTaskXml -Force) }
        if ($oldTaskEnabled) { Enable-ScheduledTask -TaskName $taskName -ErrorAction Continue | Out-Null }
    }
    throw $failure
} finally {
    if ($ownsMutex) { $setupMutex.ReleaseMutex() }
    $setupMutex.Dispose()
}
