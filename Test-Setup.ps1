#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('vmnet-sync-tests-' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$fixture = Join-Path $testRoot 'package with spaces'
[void](New-Item -ItemType Directory -Path $fixture)
foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -File) { Copy-Item -LiteralPath $file.FullName -Destination $fixture }
$script:passed = 0
$script:releaseVersion = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION')).Trim()
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body; $script:passed++; Write-Output "PASS $Name"
}
function Assert-Equal($Expected, $Actual) { if ($Expected -ne $Actual) { throw "Expected [$Expected], got [$Actual]" } }
function Assert-Throws([scriptblock]$Body) {
    $threw=$false; try { & $Body | Out-Null } catch { $threw=$true }
    if (-not $threw) { throw 'Expected an error.' }
}
$script:configPath = Join-Path $testRoot 'config'
$script:programPath = Join-Path $testRoot 'program'
$script:dataPath = Join-Path $testRoot 'data'
$script:registryPath = Join-Path $testRoot 'registry'
[void](New-Item -ItemType Directory -Path $script:registryPath)
$script:fakeTask = $null
$script:policy = 2
$script:registryPolicy = 2
$script:registerFailure = $false
$script:started = 0
$script:acls = @{}
$script:waits = 0
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Audit.ps1"
. "$PSScriptRoot\Setup.Common.ps1"
function Get-VMnetRegistryRoot { return $script:registryPath }
$mockCode = @'
function Read-NetworkFiles { return [pscustomobject]@{Fingerprint='fixture'; Networks=@()} }
function Get-VMnetRegistryRoot { return $script:registryPath }
function Get-NetworkEditors { return @('C:\VMware-Test\vmnetcfg.exe') }
function Assert-ManagedDirectory($Path) {
    if (-not $Path.StartsWith($script:testRoot + '\')) { throw 'A test tried to access a real managed directory.' }
}
function New-ManagedDirectory($Path) { Assert-ManagedDirectory $Path; if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path) } }
function Initialize-AuditNative { }
function Move-LegacyInstallation { return $null }
function Complete-LegacyMigration { }
function Undo-LegacyMigration { }
function Get-TestAuditFlags { return $script:policy }
function Set-TestAuditFlags($Value) { $script:policy=[int]$Value }
function Get-TestRegistryAuditFlags { return $script:registryPolicy }
function Set-TestRegistryAuditFlags($Value) { $script:registryPolicy=[int]$Value }
function Get-Acl($LiteralPath, [switch]$Audit) {
    if (-not $script:acls.ContainsKey($LiteralPath)) {
        $script:acls[$LiteralPath]=if ($LiteralPath -eq $script:registryPath) { [Security.AccessControl.RegistrySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    }
    return $script:acls[$LiteralPath]
}
function Set-Acl($LiteralPath, $AclObject) { $script:acls[$LiteralPath]=$AclObject }
function Get-ConfigAuditAcl($Target) { return Get-Acl -LiteralPath $Target.Path -Audit }
function Set-ConfigAuditAcl($Target, $Acl) { Set-Acl -LiteralPath $Target.Path -AclObject $Acl }
function Get-ScheduledTask($TaskName, $ErrorAction) { return $script:fakeTask }
function Disable-ScheduledTask($TaskName) { $script:fakeTask.Settings.Enabled=$false }
function Enable-ScheduledTask($TaskName, $ErrorAction) { $script:fakeTask.Settings.Enabled=$true }
function Export-ScheduledTask($TaskName) { return $script:fakeTask.Xml }
function Wait-WorkerExit($TaskName) { $script:waits++ }
function Register-ScheduledTask($TaskName, $Xml, [switch]$Force) {
    if ($script:registerFailure) { $script:registerFailure=$false; throw 'Simulated task registration failure' }
    $script:fakeTask=[pscustomobject]@{ Settings=[pscustomobject]@{Enabled=$true}; Xml=$Xml }
}
function Unregister-ScheduledTask($TaskName, $Confirm, $ErrorAction) { $script:fakeTask=$null }
function Start-ScheduledTask { $script:started++; throw 'Installer must not start a worker.' }
'@
function Write-FixtureScript([string]$Name) {
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name))
    $source=[regex]::Replace($source, '(?m)^#Requires -RunAsAdministrator\r?\n', '')
    $source=[regex]::Replace($source, '(?m)^\$admin = .*$', '$admin = $true')
    foreach ($assignment in @(
        @{Old="`$config = Join-Path `$env:ProgramData 'VMware'"; New="`$config = `$script:configPath"},
        @{Old="`$destination = Join-Path `$env:ProgramFiles 'VmnetSync'"; New="`$destination = `$script:programPath"},
        @{Old="`$dataDirectory = Join-Path `$env:ProgramData 'VmnetSync'"; New="`$dataDirectory = `$script:dataPath"},
        @{Old="(Join-Path `$env:ProgramData 'VMware')"; New='($script:configPath)'},
        @{Old='[VmnetSync.AuditNative]::GetFlags()'; New='(Get-TestAuditFlags)'},
        @{Old='[VmnetSync.AuditNative]::SetFlags('; New='Set-TestAuditFlags ('},
        @{Old='[VmnetSync.AuditNative]::GetRegistryFlags()'; New='(Get-TestRegistryAuditFlags)'},
        @{Old='[VmnetSync.AuditNative]::SetRegistryFlags('; New='Set-TestRegistryAuditFlags ('},
        @{Old='Global\VmnetSync.Setup'; New=('Local\VmnetSync.Test.' + [Guid]::NewGuid().ToString('N'))}
    )) { $source=$source.Replace($assignment.Old,$assignment.New) }
    $source=$source.Replace('$ownsMutex = $false', ('$ownsMutex = $false' + "`r`n" + $mockCode))
    [IO.File]::WriteAllText((Join-Path $fixture $Name),$source)
}
try {
    Write-FixtureScript 'Install.ps1'
    # The installer must copy a real uninstall script; tests invoke a separately
    # transformed copy later, so package-file checks still exercise real names.
    foreach ($name in @('vmnetnat.conf','vmnetdhcp.conf')) {
        if (-not (Test-Path -LiteralPath $script:configPath)) { [void](New-Item -ItemType Directory -Path $script:configPath) }
        [IO.File]::WriteAllText((Join-Path $script:configPath $name),'test fixture')
    }
    Test-Case 'Fresh install registers an event-only task without starting a worker' {
        . (Join-Path $fixture 'Install.ps1') | Out-Null
        Assert-Equal 0 $script:started
        Assert-Equal 3 $script:policy
        Assert-Equal 3 $script:registryPolicy
        [xml]$xml=$script:fakeTask.Xml
        Assert-Equal 1 $xml.Task.Triggers.ChildNodes.Count
        Assert-Equal 'EventTrigger' $xml.Task.Triggers.FirstChild.Name
        $script:firstManifest=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')) | ConvertFrom-Json
        Assert-Equal 2 $script:firstManifest.OriginalAuditFlags
        Assert-Equal $script:releaseVersion $script:firstManifest.ProductVersion
        Assert-Equal 2 $script:firstManifest.Version
        Assert-Equal 4 @($script:firstManifest.AuditEntries).Count
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $script:dataPath 'baseline.json'))
    }
    Test-Case 'Repeat install preserves the initial audit baseline and does not start a worker' {
        . (Join-Path $fixture 'Install.ps1') | Out-Null
        $again=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')) | ConvertFrom-Json
        Assert-Equal 2 $again.OriginalAuditFlags
        Assert-Equal $script:firstManifest.AuditEntries[0].AddedRights $again.AuditEntries[0].AddedRights
        Assert-Equal 0 $script:started
        Assert-Equal $true $script:fakeTask.Settings.Enabled
        Assert-Equal 1 $script:waits
    }
    Test-Case 'Failed upgrade restores installed files, manifest and the previously enabled task' {
        $before=[IO.File]::ReadAllText((Join-Path $script:programPath 'VERSION'))
        $manifestBefore=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json'))
        $baselineBefore=[IO.File]::ReadAllText((Join-Path $script:dataPath 'baseline.json'))
        [IO.File]::WriteAllText((Join-Path $fixture 'VERSION'),'0.2.0')
        $script:registerFailure=$true
        Assert-Throws { . (Join-Path $fixture 'Install.ps1') }
        Assert-Equal $before ([IO.File]::ReadAllText((Join-Path $script:programPath 'VERSION')))
        Assert-Equal $manifestBefore ([IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')))
        Assert-Equal $baselineBefore ([IO.File]::ReadAllText((Join-Path $script:dataPath 'baseline.json')))
        Assert-Equal $true $script:fakeTask.Settings.Enabled
        Assert-Equal 0 $script:started
    }
    Test-Case 'A manifest pointing outside VMware cannot be used to remove unrelated audit rules' {
        . (Join-Path $PSScriptRoot 'Audit.ps1')
        . (Join-Path $PSScriptRoot 'Setup.Common.ps1')
        $bad=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')) | ConvertFrom-Json
        $bad.AuditEntries[0].Path='C:\unrelated'
        Assert-Throws { Assert-InstallManifest $bad $script:configPath }
    }
    Test-Case 'Version 0.1 manifest migrates from file-only auditing without losing original rights' {
        $legacy=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')) | ConvertFrom-Json
        $legacy.Version=1; $legacy.ProductVersion='0.1.0'
        $legacy.AuditEntries=@($legacy.AuditEntries | Where-Object { $_.Path -ne $script:registryPath })
        [IO.File]::WriteAllText((Join-Path $script:programPath 'installation.json'),($legacy | ConvertTo-Json -Depth 8))
        # Model a true v1 installation: no registry SACL, no registry success audit.
        $script:acls[$script:registryPath]=[Security.AccessControl.RegistrySecurity]::new()
        $script:registryPolicy=2
        Assert-InstallManifest $legacy $script:configPath
        . (Join-Path $fixture 'Install.ps1') | Out-Null
        $upgraded=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')) | ConvertFrom-Json
        Assert-Equal 2 $upgraded.Version
        Assert-Equal 4 @($upgraded.AuditEntries).Count
        Assert-Equal $legacy.AuditEntries[0].AddedRights $upgraded.AuditEntries[0].AddedRights
        Assert-Equal 3 $script:registryPolicy; Assert-Equal 0 $script:started
    }
    Test-Case 'Manifest cannot add arbitrary registry cleanup targets' {
        $bad=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')) | ConvertFrom-Json
        $bad.AuditEntries[3].Path='HKLM:\SOFTWARE\Unrelated'
        Assert-Throws { Assert-InstallManifest $bad $script:configPath }
    }
    Test-Case 'Reinstall recovers a damaged baseline without starting a worker' {
        [IO.File]::WriteAllText((Join-Path $script:dataPath 'baseline.json'),'invalid json')
        . (Join-Path $fixture 'Install.ps1') | Out-Null
        Assert-Equal 2 (Read-ValidBaseline (Join-Path $script:dataPath 'baseline.json')).Version
        Assert-Equal 0 $script:started
    }
    Test-Case 'Upgrade resnapshots legacy text fingerprints without starting or inspecting adapters' {
        $legacyBaselinePath=Join-Path $script:dataPath 'baseline.json'
        Write-JsonAtomic $legacyBaselinePath ([pscustomobject]@{Version=2;Networks=@()})
        . (Join-Path $fixture 'Install.ps1') | Out-Null
        Assert-Equal 3 (Read-ValidBaseline $legacyBaselinePath).FingerprintVersion
        Assert-Equal 0 $script:started
    }
    Test-Case 'Upgrade resnapshots fingerprints that omitted registry masks without starting a worker' {
        $legacyBaselinePath=Join-Path $script:dataPath 'baseline.json'
        Write-JsonAtomic $legacyBaselinePath ([pscustomobject]@{Version=2;FingerprintVersion=2;Networks=@()})
        . (Join-Path $fixture 'Install.ps1') | Out-Null
        Assert-Equal 3 (Read-ValidBaseline $legacyBaselinePath).FingerprintVersion
        Assert-Equal 0 $script:started
    }
    Test-Case 'Uninstall removes known product files and task, retains diagnostics and audit policy' {
        Write-FixtureScript 'Uninstall.ps1'
        [IO.File]::WriteAllText((Join-Path $script:dataPath 'last-result.json'),'{"Status":"fixture"}')
        . (Join-Path $fixture 'Uninstall.ps1') | Out-Null
        Assert-Equal $null $script:fakeTask
        Assert-Equal $false (Test-Path -LiteralPath (Join-Path $script:programPath 'installation.json'))
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $script:dataPath 'last-result.json'))
        Assert-Equal 3 $script:policy
        foreach ($acl in $script:acls.Values) { Assert-Equal 0 $acl.GetAuditRules($true,$false,[Security.Principal.SecurityIdentifier]).Count }
    }
    Test-Case 'Reinstall succeeds with the diagnostic directory retained after uninstall' {
        [IO.File]::WriteAllText((Join-Path $fixture 'VERSION'),$script:releaseVersion)
        . (Join-Path $fixture 'Install.ps1') | Out-Null
        Assert-Equal $true (Test-Path -LiteralPath (Join-Path $script:programPath 'installation.json'))
        Assert-Equal 0 $script:started
    }
    Write-Output "Passed $script:passed setup tests. All system APIs were mocked; file changes stayed in the temporary fixture."
} finally {
    # Delete only the resolved, uniquely created fixture under the system temp dir.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'vmnet-sync-tests-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
