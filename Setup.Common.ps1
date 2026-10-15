#Requires -Version 5.1
function Assert-ManagedDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Not a regular managed directory: $Path" }
    # Do not run SYSTEM code or write SYSTEM state through user-writable paths.
    $allowed = @('S-1-5-18', 'S-1-5-32-544')
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    # TrustedInstaller is also an acceptable owner of a Program Files directory.
    if ($owner -notin ($allowed + @('S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'))) { throw "Unexpected directory owner: $Path" }
    $writeMask = [int][Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and ([int]$rule.FileSystemRights -band $writeMask) -ne 0 -and $rule.IdentityReference.Value -notin $allowed) {
            throw "Directory allows modification by another principal: $Path ($($rule.IdentityReference.Value))"
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $Path -Force) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse points are not supported: $($file.FullName)" }
        if (-not $file.PSIsContainer) {
            $fileAcl = Get-Acl -LiteralPath $file.FullName
            $fileOwner = $fileAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($fileOwner -notin $allowed) { throw "Unexpected file owner: $($file.FullName)" }
            foreach ($fileRule in $fileAcl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                if ($fileRule.AccessControlType -eq 'Allow' -and ([int]$fileRule.FileSystemRights -band $writeMask) -ne 0 -and $fileRule.IdentityReference.Value -notin $allowed) {
                    throw "File allows modification by another principal: $($file.FullName)"
                }
            }
        }
    }
}

function New-ManagedDirectory([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Assert-ManagedDirectory $Path; return }
    [void](New-Item -Path $Path -ItemType Directory)
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    $users = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($users, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-NetworkEditors {
    $install = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMware Workstation' -ErrorAction SilentlyContinue
    if (-not $install) { $install = Get-ItemProperty 'HKLM:\SOFTWARE\VMware, Inc.\VMware Workstation' -ErrorAction SilentlyContinue }
    if (-not $install -or -not $install.InstallPath) { throw 'VMware Workstation was not found. Install VMware Workstation first.' }
    $editors = @('vmnetcfg.exe', 'vnetlib.exe', 'vnetlib64.exe', 'vmware.exe' | ForEach-Object { Join-Path $install.InstallPath $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if ($editors.Count -eq 0) { throw 'VMware network editor executables were not found.' }
    return $editors
}

function Wait-WorkerExit([string]$TaskName) {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $task = $scheduler.GetFolder('\').GetTask($TaskName)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($task.GetInstances(0).Count -gt 0) {
        if ($timer.Elapsed.TotalSeconds -gt 130) { throw 'A worker is still running. Try again after it exits.' }
        Start-Sleep -Seconds 1
    }
}

function Assert-InstallManifest($Manifest, [string]$ConfigDirectory, [string]$ExpectedTaskName='VmnetSync-AfterConfigWrite') {
    if ($ExpectedTaskName -notin @('VmnetSync-AfterConfigWrite','Vmnet8Sync-AfterConfigWrite')) { throw 'Invalid expected task name.' }
    if ($Manifest.TaskName -ne $ExpectedTaskName -or $Manifest.Version -notin @(1,2) -or
        $Manifest.ConfigDirectory -ine $ConfigDirectory -or $null -eq $Manifest.AuditEntries) { throw 'Unexpected installation manifest; refusing to overwrite it.' }
    $targets = @(Get-ConfigAuditTargets $ConfigDirectory)
    if ($Manifest.Version -eq 1) { $targets = @($targets | Where-Object { -not $_.PSObject.Properties['Kind'] }) }
    if (@($Manifest.AuditEntries).Count -ne $targets.Count) { throw 'Incomplete installation manifest.' }
    foreach ($target in $targets) {
        $entries = @($Manifest.AuditEntries | Where-Object { $_.Path -ieq $target.Path })
        if ($entries.Count -ne 1 -or $null -eq $entries[0].AddedRights -or
            ([int]$entries[0].AddedRights -band (-bnot [int]$target.Rights)) -ne 0) { throw 'Unexpected audit entry in installation manifest.' }
    }
}

function Move-LegacyInstallation([string]$ConfigDirectory, [string]$Destination, [string]$DataDirectory,
    [string]$LegacyDestination=(Join-Path $env:ProgramFiles 'Vmnet8Sync'),
    [string]$LegacyData=(Join-Path $env:ProgramData 'Vmnet8Sync')) {
    $legacyManifest=Join-Path $LegacyDestination 'installation.json'
    if (-not (Test-Path -LiteralPath $legacyManifest)) { return $null }
    if ((Test-Path -LiteralPath $Destination) -or (Test-Path -LiteralPath $DataDirectory)) {
        throw 'Both legacy and new product directories exist. Uninstall the legacy installation before proceeding.'
    }
    Assert-ManagedDirectory $LegacyDestination
    Assert-ManagedDirectory $LegacyData
    $bytes=[IO.File]::ReadAllBytes($legacyManifest)
    $manifest=[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xfeff) | ConvertFrom-Json
    Assert-InstallManifest $manifest $ConfigDirectory 'Vmnet8Sync-AfterConfigWrite'
    $task=Get-ScheduledTask -TaskName $manifest.TaskName -ErrorAction SilentlyContinue
    $migration=[pscustomobject]@{Destination=$Destination;DataDirectory=$DataDirectory;LegacyDestination=$LegacyDestination;LegacyData=$LegacyData;Manifest=$bytes;TaskName=$manifest.TaskName;TaskXml=$null;TaskEnabled=$false;ProgramMoved=$false;DataMoved=$false;TaskRemoved=$false}
    try {
        if ($task) {
            $migration.TaskXml=Export-ScheduledTask -TaskName $manifest.TaskName
            $migration.TaskEnabled=$task.Settings.Enabled
            Disable-ScheduledTask -TaskName $manifest.TaskName | Out-Null
            Wait-WorkerExit $manifest.TaskName
        }
        # Move only these explicitly selected, validated product directories.
        Move-Item -LiteralPath $LegacyDestination -Destination $Destination
        $migration.ProgramMoved=$true
        if (Test-Path -LiteralPath $LegacyData) {
            Move-Item -LiteralPath $LegacyData -Destination $DataDirectory
            $migration.DataMoved=$true
        }
        $manifest.TaskName='VmnetSync-AfterConfigWrite'
        [IO.File]::WriteAllText((Join-Path $Destination 'installation.json'),($manifest | ConvertTo-Json -Depth 8))
        return $migration
    } catch { Undo-LegacyMigration $migration; throw }
}

function Undo-LegacyMigration($Migration) {
    if ($null -eq $Migration) { return }
    if ($Migration.ProgramMoved) {
        [IO.File]::WriteAllBytes((Join-Path $Migration.Destination 'installation.json'),$Migration.Manifest)
        Move-Item -LiteralPath $Migration.Destination -Destination $Migration.LegacyDestination
    }
    if ($Migration.DataMoved) { Move-Item -LiteralPath $Migration.DataDirectory -Destination $Migration.LegacyData }
    elseif (Test-Path -LiteralPath $Migration.DataDirectory) {
        # Setup may have created a fresh data directory when the legacy data
        # directory was missing. An empty leftover would block the next upgrade.
        Assert-ManagedDirectory $Migration.DataDirectory
        if (@(Get-ChildItem -LiteralPath $Migration.DataDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $Migration.DataDirectory }
    }
    if ($Migration.TaskRemoved) { [void](Register-ScheduledTask -TaskName $Migration.TaskName -Xml $Migration.TaskXml -Force) }
    if ($Migration.TaskEnabled) { Enable-ScheduledTask -TaskName $Migration.TaskName | Out-Null }
}

function Complete-LegacyMigration($Migration) {
    if ($null -ne $Migration -and $null -ne $Migration.TaskXml) {
        Unregister-ScheduledTask -TaskName $Migration.TaskName -Confirm:$false
        $Migration.TaskRemoved=$true
    }
}
