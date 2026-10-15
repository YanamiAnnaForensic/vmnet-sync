#Requires -Version 5.1
#Requires -RunAsAdministrator
param(
    [string]$SourceDirectory=$PSScriptRoot,
    [string]$ResultPath=(Join-Path ([IO.Path]::GetTempPath()) 'vmnet-sync-integration-result.json')
)
$ErrorActionPreference='Stop'
$integrationId=[guid]::NewGuid().ToString('N')
$integrationRoot=Join-Path $env:ProgramData ('VmnetSync-Integration-'+$integrationId)
$integrationRegistry='HKLM:\SOFTWARE\VmnetSync-Integration-'+$integrationId
$integrationTask='VmnetSync-Integration-'+$integrationId
$integrationReport=[ordered]@{Time=(Get-Date -Format o);Status='Starting';Tests=@();ActualNetworkChanges=$false;Cleanup='Pending'}
$integrationOldFileFlags=$null; $integrationOldRegistryFlags=$null
$integrationTaskCreated=$false; $integrationExit=1
try {
    . (Join-Path $SourceDirectory 'Sync.ps1') -Mode Check
    . (Join-Path $SourceDirectory 'Audit.ps1')
    . (Join-Path $SourceDirectory 'Setup.Common.ps1')
    $integrationRealConfig=Join-Path $env:ProgramData 'VMware'
    $integrationRealSnapshot=Read-NetworkFiles $integrationRealConfig
    $integrationInventory=@(Read-VMnetInventory | Where-Object {$_.Id -in @('VMnet1','VMnet8')})
    foreach ($integrationNetworkId in @('VMnet1','VMnet8')) {
        $integrationDesired=@($integrationRealSnapshot.Networks | Where-Object {$_.Id -eq $integrationNetworkId})
        if ($integrationDesired.Count -ne 1 -or $integrationDesired[0].Disposition -ne 'Ready') { throw "Required network is not ready: $integrationNetworkId" }
        if ((Get-NetworkObservation $integrationDesired[0]).Status -ne 'Synced') { throw "Live network must match before this test: $integrationNetworkId" }
    }
    New-ManagedDirectory $integrationRoot
    $integrationConfig=Join-Path $integrationRoot 'config'
    New-ManagedDirectory $integrationConfig
    New-ManagedDirectory (Join-Path $integrationRoot 'VmnetSync')
    foreach ($integrationFile in @('Sync.ps1','Core.ps1','Audit.ps1')) { Copy-Item -LiteralPath (Join-Path $SourceDirectory $integrationFile) -Destination $integrationRoot }
    # Keep the fixture's worker mutex separate from installed workers/tests.
    $integrationSyncPath=Join-Path $integrationRoot 'Sync.ps1'
    $integrationSyncSource=[IO.File]::ReadAllText($integrationSyncPath).Replace('Global\VmnetSync.Worker',('Global\VmnetSync.Integration.'+$integrationId))
    [IO.File]::WriteAllText($integrationSyncPath,$integrationSyncSource,[Text.Encoding]::UTF8)
    foreach ($integrationFile in @('vmnetnat.conf','vmnetdhcp.conf')) { Copy-Item -LiteralPath (Join-Path $integrationRealConfig $integrationFile) -Destination $integrationConfig }
    $integrationReport.IsAdministrator=Test-Administrator
    # Open an explicitly writable handle; do not reuse a provider read handle.
    $integrationNativeKey=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey(('SOFTWARE\VmnetSync-Integration-'+$integrationId))
    $integrationNativeKey.Dispose()
    foreach ($integrationEntry in $integrationInventory) {
        $integrationKey=Join-Path $integrationRegistry $integrationEntry.Id.ToLowerInvariant()
        [void](New-Item -Path $integrationKey)
        New-ItemProperty -LiteralPath $integrationKey -Name IPSubnetAddress -Value $integrationEntry.Subnet -PropertyType String | Out-Null
        if ($integrationEntry.SubnetMask -ne '') { New-ItemProperty -LiteralPath $integrationKey -Name IPSubnetMask -Value $integrationEntry.SubnetMask -PropertyType String | Out-Null }
        foreach ($integrationPart in @('Adapter','DHCP','NAT')) {
            $integrationPartKey=Join-Path $integrationKey $integrationPart
            [void](New-Item -Path $integrationPartKey)
            $integrationEnabled=switch ($integrationPart) {'Adapter' {$integrationEntry.AdapterEnabled};'DHCP' {$integrationEntry.DhcpEnabled};'NAT' {$integrationEntry.NatEnabled}}
            New-ItemProperty -LiteralPath $integrationPartKey -Name ('Use'+$integrationPart) -Value ([int]$integrationEnabled) -PropertyType DWord | Out-Null
            if ($integrationPart -eq 'NAT' -and $integrationEntry.NatEnabled) { New-ItemProperty -LiteralPath $integrationPartKey -Name GatewayIPAddress -Value $integrationEntry.Gateway -PropertyType String | Out-Null }
        }
    }
    $script:integrationFixtureRegistry=$integrationRegistry
    function Get-VMnetRegistryRoot { return $script:integrationFixtureRegistry }
    $integrationSnapshot=Read-NetworkFiles $integrationConfig
    Write-JsonAtomic (Join-Path $integrationRoot 'VmnetSync\baseline.json') (New-ConfigBaseline $integrationSnapshot)
    $integrationWrapper=@'
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Sync.ps1" -Mode Repair -ConfigDirectory "$PSScriptRoot\config" -TimeoutSeconds 45 -EventMode
$env:ProgramData=$PSScriptRoot
$script:integrationFixtureRegistry='__REGISTRY__'
function Get-VMnetRegistryRoot { return $script:integrationFixtureRegistry }
function Invoke-AdapterRenew { throw 'Integration fixture forbids changing real host network state.' }
function Restart-SharedDhcp { throw 'Integration fixture forbids restarting real services.' }
try {
    $run=@(Invoke-Synchronization)
    $run | Where-Object {$_ -isnot [int]} | Set-Content -LiteralPath "$PSScriptRoot\console.json" -Encoding UTF8
    $codes=@($run | Where-Object {$_ -is [int]})
    exit $codes[-1]
} catch {
    [IO.File]::WriteAllText("$PSScriptRoot\error.txt",($_ | Out-String)+$_.ScriptStackTrace)
    exit 1
}
'@
    $integrationWrapper=$integrationWrapper.Replace('__REGISTRY__',$integrationRegistry)
    $integrationWorker=Join-Path $integrationRoot 'IntegrationWorker.ps1'
    [IO.File]::WriteAllText($integrationWorker,$integrationWrapper,[Text.Encoding]::UTF8)
    Initialize-AuditNative
    $integrationOldFileFlags=[VmnetSync.AuditNative]::GetFlags()
    $integrationOldRegistryFlags=[VmnetSync.AuditNative]::GetRegistryFlags()
    [VmnetSync.AuditNative]::SetFlags(($integrationOldFileFlags -band 3) -bor 1)
    [VmnetSync.AuditNative]::SetRegistryFlags(($integrationOldRegistryFlags -band 3) -bor 1)
    Restore-ConfigAudit $integrationConfig
    $integrationPowerShell="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $integrationXml=New-SyncTaskXml $integrationConfig $integrationWorker @($integrationPowerShell)
    [void](Register-ScheduledTask -TaskName $integrationTask -Xml $integrationXml)
    $integrationTaskCreated=$true
    $integrationScheduler=New-Object -ComObject 'Schedule.Service'
    $integrationScheduler.Connect()
    $integrationTaskObject=$integrationScheduler.GetFolder('\').GetTask($integrationTask)
    if ($integrationTaskObject.GetInstances(0).Count -ne 0) { throw 'Registration unexpectedly started the worker.' }
    $integrationReport.Tests+=@{Name='Task registration does not start worker';Status='Passed'}

    function Wait-IntegrationResult([string]$ExpectedId,[string]$ExpectedStatus,[DateTime]$Since) {
        $integrationWait=[Diagnostics.Stopwatch]::StartNew()
        $integrationResultFile=Join-Path $integrationRoot 'VmnetSync\last-result.json'
        while ($integrationWait.Elapsed.TotalSeconds -lt 65) {
            if (Test-Path -LiteralPath (Join-Path $integrationRoot 'error.txt')) { throw ([IO.File]::ReadAllText((Join-Path $integrationRoot 'error.txt'))) }
            if (Test-Path -LiteralPath $integrationResultFile) {
                $integrationRun=[IO.File]::ReadAllText($integrationResultFile) | ConvertFrom-Json
                if ([DateTime]$integrationRun.Time -ge $Since) {
                    if (@($integrationRun.Networks).Count -ne 1 -or $integrationRun.Networks[0].Id -ne $ExpectedId -or $integrationRun.Status -ne $ExpectedStatus) { throw "Unexpected worker result: $($integrationRun | ConvertTo-Json -Depth 4 -Compress)" }
                    if (@($integrationRun.Changes).Count -ne 0) { throw 'Integration worker attempted a real network change.' }
                    $integrationCurrentTask=$integrationScheduler.GetFolder('\').GetTask($integrationTask)
                    if ($integrationCurrentTask.GetInstances(0).Count -eq 0 -and $integrationCurrentTask.LastTaskResult -eq 0) { return $integrationRun }
                }
            }
            Start-Sleep -Seconds 1
        }
        throw "Timed out waiting for event-triggered $ExpectedId/$ExpectedStatus"
    }

    # Change only a cloned pool, leaving real service configuration untouched.
    $integrationDhcpPath=Join-Path $integrationConfig 'vmnetdhcp.conf'
    $integrationDhcp=[IO.File]::ReadAllText($integrationDhcpPath)
    $integrationHostOnly=@($integrationSnapshot.Networks | Where-Object {$_.Id -eq 'VMnet1'})[0]
    $integrationSubnet=@(Get-DhcpBlocks $integrationDhcp '^\s*subnet\s+([\d.]+)\s+netmask\s+([\d.]+)\s*\{' | Where-Object {$_.Header.Groups[1].Value -eq $integrationHostOnly.Network.Split('/')[0]})[0]
    $integrationRange=Get-UniqueMatch $integrationSubnet.Body '^\s*range\s+([\d.]+)\s+([\d.]+)\s*;' 'host-only DHCP range'
    $integrationLast=ConvertTo-IPv4Number $integrationRange.Groups[2].Value
    $integrationNewBody=$integrationSubnet.Body.Replace($integrationRange.Groups[2].Value,(ConvertFrom-IPv4Number ($integrationLast-1)))
    $integrationSince=Get-Date
    [IO.File]::WriteAllText($integrationDhcpPath,$integrationDhcp.Replace($integrationSubnet.Body,$integrationNewBody))
    $integrationRun=Wait-IntegrationResult 'VMnet1' 'Synced' $integrationSince
    $integrationReport.Tests+=@{Name='4663 file write starts SYSTEM worker; only VMnet1 is checked; worker exits';Status='Passed';ElapsedSeconds=$integrationRun.ElapsedSeconds}

    $integrationSince=Get-Date
    Set-ItemProperty -LiteralPath (Join-Path $integrationRegistry 'vmnet8\Adapter') -Name UseAdapter -Value 0
    $integrationRun=Wait-IntegrationResult 'VMnet8' 'Skipped' $integrationSince
    $integrationReport.Tests+=@{Name='4657 registry-only edit starts worker; host connection opt-out is skipped';Status='Passed';ElapsedSeconds=$integrationRun.ElapsedSeconds}
    $integrationSince=Get-Date
    Set-ItemProperty -LiteralPath (Join-Path $integrationRegistry 'vmnet8\Adapter') -Name UseAdapter -Value 1
    $integrationRun=Wait-IntegrationResult 'VMnet8' 'Synced' $integrationSince
    $integrationReport.Tests+=@{Name='Registry-only reconnect checks NAT network and exits';Status='Passed';ElapsedSeconds=$integrationRun.ElapsedSeconds}

    Start-Sleep -Seconds 4
    $integrationBefore=$integrationScheduler.GetFolder('\').GetTask($integrationTask).LastRunTime
    [void](Read-NetworkFiles $integrationConfig)
    Start-Sleep -Seconds 7
    $integrationAfter=$integrationScheduler.GetFolder('\').GetTask($integrationTask)
    if ($integrationBefore -ne $integrationAfter.LastRunTime -or $integrationAfter.GetInstances(0).Count -ne 0) { throw 'Read-only inspection triggered a worker.' }
    $integrationReport.Tests+=@{Name='Configuration reads do not start worker and no worker remains resident';Status='Passed'}
    $integrationEvents=@(Get-WinEvent -FilterHashtable @{LogName='Security';Id=4663,4657;StartTime=(Get-Date).AddMinutes(-5)} -ErrorAction SilentlyContinue | Where-Object {$_.ToXml().Contains('VmnetSync-Integration-'+$integrationId)})
    $integrationReport.EventIds=@($integrationEvents.Id | Sort-Object -Unique)
    if (4663 -notin $integrationReport.EventIds -or 4657 -notin $integrationReport.EventIds) { throw 'Missing expected Security audit event IDs.' }
    $integrationRegistryTarget=[pscustomobject]@{Path=$integrationRegistry;AddedRights=2}
    Remove-AddedConfigAudit $integrationRegistryTarget $integrationConfig
    $integrationChildTarget=[pscustomobject]@{Path=($integrationRegistry+'\vmnet8\Adapter');Kind='Registry'}
    $integrationChildAcl=Get-ConfigAuditAcl $integrationChildTarget
    if ($integrationChildAcl.GetAuditRules($true,$true,[Security.Principal.SecurityIdentifier]).Count -ne 0) { throw 'Tool-added audit inheritance remained on the existing child after removal.' }
    $integrationReport.Tests+=@{Name='Removing registry audit rule also removes inherited child rules';Status='Passed'}
    $integrationReport.Status='Passed'; $integrationExit=0
} catch {
    $integrationReport.Status='Failed'; $integrationReport.Error=$_.Exception.Message
    $integrationReport.Position=$_.InvocationInfo.PositionMessage; $integrationReport.Stack=$_.ScriptStackTrace
    if ($null -ne $integrationOldFileFlags) {
        try {
            $integrationReport.RegistryAcls=@(
                foreach ($auditSuffix in @('','\vmnet8','\vmnet8\Adapter')) {
                    $auditTarget=[pscustomobject]@{Path=($integrationRegistry+$auditSuffix);Kind='Registry'}
                    $auditAcl=Get-ConfigAuditAcl $auditTarget
                    [pscustomobject]@{Suffix=$auditSuffix;Sddl=$auditAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Audit)}
                }
            )
            $integrationReport.Events=@(
                Get-WinEvent -FilterHashtable @{LogName='Security';Id=4657,4663;StartTime=(Get-Date).AddMinutes(-5)} -ErrorAction SilentlyContinue |
                    Where-Object {$_.ToXml().Contains($integrationId)} |
                    ForEach-Object {[xml]$eventXml=$_.ToXml();[pscustomobject]@{Id=$_.Id;Data=@($eventXml.Event.EventData.Data | Where-Object {$_.Name -in @('ObjectName','ObjectValueName','AccessMask','ProcessName')} | ForEach-Object {$_.Name+'='+$_.'#text'})}}
            )
        } catch {$integrationReport.DiagnosticError=$_.Exception.Message}
    }
} finally {
    try {
        if ($integrationTaskCreated) {
            Disable-ScheduledTask -TaskName $integrationTask | Out-Null
            Wait-WorkerExit $integrationTask
            Unregister-ScheduledTask -TaskName $integrationTask -Confirm:$false
        }
        if ($integrationRegistry -notmatch '^HKLM:\\SOFTWARE\\VmnetSync-Integration-[0-9a-f]{32}$') { throw 'Unexpected registry cleanup path.' }
        [Microsoft.Win32.Registry]::LocalMachine.DeleteSubKeyTree(('SOFTWARE\VmnetSync-Integration-'+$integrationId),$false)
        if (Test-Path -LiteralPath $integrationRoot) {
            $integrationResolved=[IO.Path]::GetFullPath($integrationRoot)
            $integrationExpectedParent=[IO.Path]::GetFullPath($env:ProgramData).TrimEnd('\')+'\'
            if (-not $integrationResolved.StartsWith($integrationExpectedParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($integrationResolved) -notmatch '^VmnetSync-Integration-[0-9a-f]{32}$') { throw 'Unexpected filesystem cleanup path.' }
            Remove-Item -LiteralPath $integrationResolved -Recurse -Force
        }
        $integrationReport.Cleanup='Passed'
    } catch { $integrationReport.Cleanup='Failed';$integrationReport.CleanupError=$_.Exception.Message;$integrationExit=1 }
    if ($null -ne $integrationOldFileFlags) { [VmnetSync.AuditNative]::SetFlags($integrationOldFileFlags) }
    if ($null -ne $integrationOldRegistryFlags) { [VmnetSync.AuditNative]::SetRegistryFlags($integrationOldRegistryFlags) }
    if ($null -ne $integrationOldFileFlags -and $null -ne $integrationOldRegistryFlags) {
        $integrationReport.AuditPolicyRestored=(([VmnetSync.AuditNative]::GetFlags() -band 3) -eq ($integrationOldFileFlags -band 3) -and ([VmnetSync.AuditNative]::GetRegistryFlags() -band 3) -eq ($integrationOldRegistryFlags -band 3))
        if (-not $integrationReport.AuditPolicyRestored) { $integrationReport.Cleanup='Failed';$integrationExit=1 }
    }
    [IO.File]::WriteAllText($ResultPath,($integrationReport | ConvertTo-Json -Depth 8),[Text.Encoding]::UTF8)
}
exit $integrationExit
