#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Audit.ps1"
# Tests also run on CI hosts without VMware. No registry access is required.
function Get-VMnetRegistryRoot { return 'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib\VMnetConfig' }
$script:passed = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
function Assert-Equal($Expected, $Actual) {
    if ($Expected -ne $Actual) { throw "Expected [$Expected], got [$Actual]" }
}
function Assert-Throws([scriptblock]$Body) {
    $threw = $false
    try { & $Body | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'Expected rejection, but operation succeeded.' }
}
$nat = @'
[host]
ip = 192.168.36.2/24
hostIp = 192.168.36.1
device = vmnet8
[incomingtcp]
2222 = 192.168.36.111:22
'@
$dhcp = @'
subnet 192.168.93.0 netmask 255.255.255.0 {
range 192.168.93.128 192.168.93.254;
}
host VMnet1 {
hardware ethernet 00:50:56:c0:00:01;
fixed-address 192.168.93.1;
}
subnet 192.168.36.0 netmask 255.255.255.0 {
range 192.168.36.128 192.168.36.254;
option routers 192.168.36.2;
}
host VMnet8 {
hardware ethernet 00:50:56:c0:00:08;
fixed-address 192.168.36.1;
}
'@
$desired = Read-DesiredNetwork $nat $dhcp
function New-Actual {
    return [pscustomobject]@{
        AdapterCount=1; Mac='005056C00008'; Status='Up'; DhcpEnabled=$true
        DirectRoute=$true; DefaultRoute=$false; ServicesRunning=$true
        Addresses=@([pscustomobject]@{ IPAddress='192.168.36.1'; PrefixLength=24; AddressState='Preferred' })
    }
}
Test-Case 'VMnet8 selected independently of VMnet1' { Assert-Equal '192.168.36.1' $desired.HostIP; Assert-Equal '192.168.36.0/24' $desired.Network }
Test-Case 'Comments do not supply stale configuration values' {
    $result = Read-DesiredNetwork ($nat + "`n# hostIp = 192.168.56.1") ("# host VMnet8 { }`n" + $dhcp)
    Assert-Equal '192.168.36.1' $result.HostIP
}
Test-Case 'Half-written files are rejected' { Assert-Throws { Read-DesiredNetwork $nat ($dhcp.Substring(0, $dhcp.LastIndexOf('}'))) } }
Test-Case 'Cross-file disagreement is rejected' { Assert-Throws { Read-DesiredNetwork ($nat.Replace('192.168.36.1','192.168.56.1')) $dhcp } }
Test-Case 'Wrong NAT device is rejected' { Assert-Throws { Read-DesiredNetwork ($nat.Replace('vmnet8','vmnet1')) $dhcp } }
Test-Case 'Mask mismatch is rejected' { Assert-Throws { Read-DesiredNetwork ($nat.Replace('/24','/25')) $dhcp } }
Test-Case 'Noncontiguous mask is rejected' { Assert-Throws { Read-DesiredNetwork $nat ($dhcp.Replace('255.255.255.0','255.0.255.0')) } }
Test-Case 'DHCP router disagreement is rejected' { Assert-Throws { Read-DesiredNetwork $nat ($dhcp.Replace('option routers 192.168.36.2','option routers 192.168.36.3')) } }
Test-Case 'DHCP pool cannot include reserved host address' { Assert-Throws { Read-DesiredNetwork $nat ($dhcp.Replace('range 192.168.36.128','range 192.168.36.1')) } }
Test-Case 'DHCP pool cannot include broadcast address' { Assert-Throws { Read-DesiredNetwork $nat ($dhcp.Replace('192.168.36.254','192.168.36.255')) } }
Test-Case 'Duplicate host reservation is rejected' { Assert-Throws { Read-DesiredNetwork $nat ($dhcp + "`nhost VMnet8 { fixed-address 192.168.36.1; }") } }
Test-Case 'Non-/24 subnet is parsed correctly' {
    $result = Read-DesiredNetwork ($nat.Replace('/24','/23')) ($dhcp.Replace('255.255.255.0','255.255.254.0').Replace('subnet 192.168.93.0','subnet 192.168.92.0'))
    Assert-Equal '192.168.36.0/23' $result.Network
}
Test-Case 'Invalid IPv4 is rejected' { Assert-Throws { ConvertTo-IPv4Number '192.168.999.1' }; Assert-Throws { ConvertTo-IPv4Number '127.1' } }
Test-Case 'Exact live address, prefix and route are synchronized' { Assert-Equal 'Synced' (Get-SyncDecision $desired (New-Actual)) }
Test-Case 'Original stale DHCP lease requests repair' {
    $actual = New-Actual; $actual.Addresses[0].IPAddress='192.168.56.1'; $actual.DirectRoute=$false
    Assert-Equal 'Repair' (Get-SyncDecision $desired $actual)
}
Test-Case 'Correct IP with wrong mask is not synchronized' {
    $actual = New-Actual; $actual.Addresses[0].PrefixLength=16
    Assert-Equal 'Repair' (Get-SyncDecision $desired $actual)
}
Test-Case 'Tentative or duplicate IP is not synchronized' {
    foreach ($state in @('Tentative','Duplicate')) {
        $actual = New-Actual; $actual.Addresses[0].AddressState=$state
        Assert-Equal 'Repair' (Get-SyncDecision $desired $actual)
    }
}
Test-Case 'Missing on-link route is not synchronized' {
    $actual = New-Actual; $actual.DirectRoute=$false
    Assert-Equal 'Repair' (Get-SyncDecision $desired $actual)
}
Test-Case 'Unexpected default route blocks mutation' {
    $actual = New-Actual; $actual.DefaultRoute=$true
    Assert-Equal $true (Get-SyncDecision $desired $actual).StartsWith('Blocked:')
}
Test-Case 'A different MAC cannot be repaired' {
    $actual = New-Actual; $actual.Mac='000000000000'
    Assert-Equal $true (Get-SyncDecision $desired $actual).StartsWith('Blocked:')
}
Test-Case 'Ambiguous or absent adapters block repair' {
    foreach ($count in @(0,2)) { $actual=New-Actual; $actual.AdapterCount=$count; Assert-Equal $true (Get-SyncDecision $desired $actual).StartsWith('Blocked:') }
}
Test-Case 'Deliberately disabled adapter is not enabled' {
    $actual=New-Actual; $actual.Status='Disabled'; Assert-Equal $true (Get-SyncDecision $desired $actual).StartsWith('Blocked:')
}
Test-Case 'Static adapter is inspected but not overwritten' {
    $actual=New-Actual; $actual.DhcpEnabled=$false
    Assert-Equal 'Synced' (Get-SyncDecision $desired $actual)
    $actual.Addresses[0].IPAddress='192.168.56.1'
    Assert-Equal $true (Get-SyncDecision $desired $actual).StartsWith('Blocked:')
}
Test-Case 'Stopped services are not reported as synchronized' {
    $actual=New-Actual; $actual.ServicesRunning=$false; Assert-Equal 'Repair' (Get-SyncDecision $desired $actual)
}
Test-Case 'Audit policy helper compiles without enabling privileges or modifying policy' {
    $source = [IO.File]::ReadAllText("$PSScriptRoot\Audit.ps1")
    $csharp = [regex]::Match($source, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    if (-not ('Vmnet8Sync.AuditNative' -as [type])) { Add-Type -TypeDefinition $csharp }
    Assert-Equal $true ($null -ne ('Vmnet8Sync.AuditNative' -as [type]))
}
Test-Case 'Existing audit rights are preserved through add/remove' {
    $acl = [Security.AccessControl.FileSecurity]::new()
    $target=[pscustomobject]@{ Rights=[Security.AccessControl.FileSystemRights]'WriteData' }
    $original=New-ConfigAuditRule $target; $acl.AddAuditRule($original)
    $target.Rights=[Security.AccessControl.FileSystemRights]'WriteData,AppendData,Delete'
    $requested=New-ConfigAuditRule $target
    $added=[int]$requested.FileSystemRights -band (-bnot (Get-ExistingAuditRights $acl $requested))
    $acl.AddAuditRule($requested)
    Assert-Equal ([int]$requested.FileSystemRights) (Get-ExistingAuditRights $acl $requested)
    $target.Rights=[Security.AccessControl.FileSystemRights]$added
    [void]$acl.RemoveAuditRule((New-ConfigAuditRule $target))
    Assert-Equal ([int][Security.AccessControl.FileSystemRights]::WriteData) (Get-ExistingAuditRights $acl $original)
}
Test-Case 'Task filters configuration writes and VMware replacement, not DHCP lease rotation' {
    [xml]$taskXml=New-SyncTaskXml 'C:\ProgramData\VMware' 'C:\Program Files\Vmnet8Sync\Sync.ps1' @('C:\VMware-Test\vmnetcfg.exe')
    [xml]$query=$taskXml.Task.Triggers.EventTrigger.Subscription
    $eventXPath=$query.QueryList.Query.Select[0].InnerText
    # band() is a Windows Event Log XPath extension, unavailable in XmlDocument.
    # Validate path/process matching here, and let the Windows engine compile
    # the complete expression in the following test.
    $xpath=$eventXPath.Replace(" and band(Data[@Name='AccessMask'],65606)", '')
    Assert-Equal $true ($eventXPath.Contains("band(Data[@Name='AccessMask'],65606)"))
    foreach ($sample in @(
        @{Path='C:\ProgramData\VMware\vmnetnat.conf'; Process='C:\VMware-Test\vmnetcfg.exe'; Match=$true},
        @{Path='C:\ProgramData\VMware\vmnetdhcp.conf'; Process='C:\VMware-Test\vmnetcfg.exe'; Match=$true},
        @{Path='C:\ProgramData\VMware'; Process='C:\VMware-Test\vmnetcfg.exe'; Match=$true},
        @{Path='C:\ProgramData\VMware'; Process='C:\Windows\SysWOW64\vmnetdhcp.exe'; Match=$false},
        @{Path='C:\ProgramData\VMware\vmnetdhcp.leases'; Process='C:\VMware-Test\vmnetcfg.exe'; Match=$false}
    )) {
        [xml]$event="<Event><System><EventID>4663</EventID></System><EventData><Data Name='ObjectName'>$($sample.Path)</Data><Data Name='ProcessName'>$($sample.Process)</Data></EventData></Event>"
        Assert-Equal $sample.Match ($event.SelectNodes($xpath).Count -eq 1)
    }
    Assert-Equal 'Queue' $taskXml.Task.Settings.MultipleInstancesPolicy
    Assert-Equal 'PT2M' $taskXml.Task.Settings.ExecutionTimeLimit
}
Test-Case 'All scripts parse under the current PowerShell engine' {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
        $errors=$null; $tokens=$null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
        if ($errors.Count -gt 0) { throw "$($file.Name): $($errors[0].Message)" }
    }
}
Test-Case 'Windows Task Scheduler accepts the definition without task registration' {
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $definition = $scheduler.NewTask(0)
    $definition.XmlText = New-SyncTaskXml 'C:\ProgramData\VMware' 'C:\Program Files\Vmnet8Sync\Sync.ps1' @('C:\VMware-Test\vmnetcfg.exe')
    # Verify Windows' interpreted settings: only a configuration event can launch
    # the worker, with no boot/logon/timer trigger, catch-up run or wake-up.
    Assert-Equal 1 $definition.Triggers.Count
    Assert-Equal 0 $definition.Triggers.Item(1).Type
    Assert-Equal $false $definition.Settings.StartWhenAvailable
    Assert-Equal $false $definition.Settings.AllowDemandStart
    Assert-Equal $false $definition.Settings.WakeToRun
    $identity = $definition.Principal.UserId
    if ($identity -notmatch '^S-') {
        $identity = ([Security.Principal.NTAccount]::new($identity)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    Assert-Equal 'S-1-5-18' $identity
}
Test-Case 'Windows Event Log accepts the write-only event query including band extension' {
    [xml]$taskXml=New-SyncTaskXml 'C:\ProgramData\VMware' 'C:\Program Files\Vmnet8Sync\Sync.ps1' @('C:\VMware-Test\vmnetcfg.exe')
    [xml]$query=$taskXml.Task.Triggers.EventTrigger.Subscription
    # Validate on the readable Application log; no Security-log access or writes.
    $eventQuery=[Diagnostics.Eventing.Reader.EventLogQuery]::new('Application', [Diagnostics.Eventing.Reader.PathType]::LogName, $query.OuterXml.Replace('Path="Security"', 'Path="Application"').Replace("Path='Security'", "Path='Application'"))
    $reader=[Diagnostics.Eventing.Reader.EventLogReader]::new($eventQuery)
    try { $entry=$reader.ReadEvent(); if ($null -ne $entry) { $entry.Dispose() } }
    finally { $reader.Dispose() }
}
Write-Output "Passed $script:passed tests. No network, task, file-audit or service settings were changed."
