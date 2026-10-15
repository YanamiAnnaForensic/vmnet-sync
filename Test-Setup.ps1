#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('vmnet8-sync-tests-' + [Guid]::NewGuid().ToString('N'))
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
$script:fakeTask = $null
$script:policy = 2
$script:registerFailure = $false
$script:started = 0
$script:acls = @{}
$script:waits = 0
$mockCode = @'
function Read-NetworkFiles { return [pscustomobject]@{} }
function Get-NetworkEditors { return @('C:\VMware-Test\vmnetcfg.exe') }
function Assert-ManagedDirectory($Path) {
    if (-not $Path.StartsWith($script:testRoot + '\')) { throw 'A test tried to access a real managed directory.' }
}
function New-ManagedDirectory($Path) { Assert-ManagedDirectory $Path; if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path) } }
function Initialize-AuditNative { }
function Get-TestAuditFlags { return $script:policy }
function Set-TestAuditFlags($Value) { $script:policy=[int]$Value }
function Get-Acl($LiteralPath, [switch]$Audit) {
    if (-not $script:acls.ContainsKey($LiteralPath)) { $script:acls[$LiteralPath]=[Security.AccessControl.FileSecurity]::new() }
    return $script:acls[$LiteralPath]
}
function Set-Acl($LiteralPath, $AclObject) { $script:acls[$LiteralPath]=$AclObject }
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
        @{Old="`$destination = Join-Path `$env:ProgramFiles 'Vmnet8Sync'"; New="`$destination = `$script:programPath"},
        @{Old="`$dataDirectory = Join-Path `$env:ProgramData 'Vmnet8Sync'"; New="`$dataDirectory = `$script:dataPath"},
        @{Old="(Join-Path `$env:ProgramData 'VMware')"; New='($script:configPath)'},
        @{Old='[Vmnet8Sync.AuditNative]::GetFlags()'; New='(Get-TestAuditFlags)'},
        @{Old='[Vmnet8Sync.AuditNative]::SetFlags('; New='Set-TestAuditFlags ('},
        @{Old='Global\Vmnet8Sync.Setup'; New=('Local\Vmnet8Sync.Test.' + [Guid]::NewGuid().ToString('N'))}
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
        [xml]$xml=$script:fakeTask.Xml
        Assert-Equal 1 $xml.Task.Triggers.ChildNodes.Count
        Assert-Equal 'EventTrigger' $xml.Task.Triggers.FirstChild.Name
        $script:firstManifest=[IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')) | ConvertFrom-Json
        Assert-Equal 2 $script:firstManifest.OriginalAuditFlags
        Assert-Equal $script:releaseVersion $script:firstManifest.ProductVersion
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
        [IO.File]::WriteAllText((Join-Path $fixture 'VERSION'),'0.2.0')
        $script:registerFailure=$true
        Assert-Throws { . (Join-Path $fixture 'Install.ps1') }
        Assert-Equal $before ([IO.File]::ReadAllText((Join-Path $script:programPath 'VERSION')))
        Assert-Equal $manifestBefore ([IO.File]::ReadAllText((Join-Path $script:programPath 'installation.json')))
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
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'vmnet8-sync-tests-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
