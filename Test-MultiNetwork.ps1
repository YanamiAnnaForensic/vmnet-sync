#Requires -Version 5.1
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Test.ps1"

Test-Case 'Host-only parses without NAT configuration or a DHCP router' {
    $hostOnly=Read-DesiredNetwork '' $dhcp 'VMnet1' $false
    Assert-Equal 'HostOnly' $hostOnly.Kind
    Assert-Equal '192.168.93.1' $hostOnly.HostIP
    Assert-Equal $null $hostOnly.Gateway
}
Test-Case 'NAT can live on custom VMnet13 with arbitrary host and gateway addresses' {
    $customNat=$nat.Replace('vmnet8','vmnet13').Replace('192.168.36.2/24','192.168.36.254/24').Replace('192.168.36.1','192.168.36.10')
    $customDhcp=$dhcp.Replace('VMnet8','VMnet13').Replace('192.168.36.1;','192.168.36.10;').Replace('routers 192.168.36.2;','routers 192.168.36.254;').Replace('192.168.36.254;','192.168.36.200;')
    # Only the range end changes; retain the explicitly chosen router.
    $customDhcp=$customDhcp.Replace('routers 192.168.36.200;','routers 192.168.36.254;')
    $custom=Read-DesiredNetwork $customNat $customDhcp 'VMnet13' $true
    Assert-Equal 'VMnet13' $custom.Id; Assert-Equal '192.168.36.10' $custom.HostIP; Assert-Equal '192.168.36.254' $custom.Gateway
}
Test-Case 'Host-only network can use a non-/24 mask' {
    $hostOnly=Read-DesiredNetwork '' ($dhcp.Replace('255.255.255.0','255.255.254.0').Replace('subnet 192.168.93.0','subnet 192.168.92.0')) 'VMnet1' $false
    Assert-Equal '192.168.92.0/23' $hostOnly.Network
}
Test-Case 'Registry audit rights are added and removed without removing existing rights' {
    $acl=[Security.AccessControl.RegistrySecurity]::new()
    $target=[pscustomobject]@{Kind='Registry'; Rights=[Security.AccessControl.RegistryRights]::QueryValues}
    $original=New-ConfigAuditRule $target; $acl.AddAuditRule($original)
    $target.Rights=[Security.AccessControl.RegistryRights]::SetValue
    $rule=New-ConfigAuditRule $target; $acl.AddAuditRule($rule)
    Assert-Equal 3 (Get-ExistingAuditRights $acl $rule)
    [void]$acl.RemoveAuditRule($rule)
    Assert-Equal 1 (Get-ExistingAuditRights $acl $original)
}
Test-Case 'Registry event queries cover configured slots and never match reads or unrelated keys' {
    [xml]$task=New-SyncTaskXml 'C:\ProgramData\VMware' 'C:\Program Files\VmnetSync\Sync.ps1' @('C:\VMware\vmnetcfg.exe')
    [xml]$query=$task.Task.Triggers.EventTrigger.Subscription
    Assert-Equal 21 @($query.QueryList.Query.Select).Count
    $prefix='\REGISTRY\MACHINE\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib\VMnetConfig'
    foreach ($sample in @(
        @{Id=4657; Path="$prefix\vmnet1\Adapter"; Match=$true},
        @{Id=4657; Path="$prefix\vmnet13\DHCP"; Match=$true},
        @{Id=4657; Path="$prefix\vmnet19\NAT"; Match=$true},
        @{Id=4657; Path="$prefix\vmnet8"; Match=$true},
        @{Id=4656; Path="$prefix\vmnet8"; Match=$false},
        @{Id=4657; Path='\REGISTRY\MACHINE\SOFTWARE\OtherProduct'; Match=$false}
    )) {
        [xml]$event="<Event><System><EventID>$($sample.Id)</EventID></System><EventData><Data Name='ObjectName'>$($sample.Path)</Data></EventData></Event>"
        $matches=@($query.QueryList.Query.Select | Select-Object -Skip 1 | Where-Object { $event.SelectNodes($_.InnerText).Count -gt 0 }).Count
        Assert-Equal $sample.Match ($matches -gt 0)
    }
}

$multiFixture=Join-Path ([IO.Path]::GetTempPath()) ('vmnet-multi-tests-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $multiFixture)
function New-Inventory {
    @(
        [pscustomobject][ordered]@{Id='VMnet0';Configured=$false;AdapterEnabled=$false;DhcpEnabled=$false;NatEnabled=$false;Subnet='';SubnetMask='';Gateway=''},
        [pscustomobject][ordered]@{Id='VMnet1';Configured=$true;AdapterEnabled=$true;DhcpEnabled=$true;NatEnabled=$false;Subnet='192.168.93.0';SubnetMask='';Gateway=''},
        [pscustomobject][ordered]@{Id='VMnet8';Configured=$true;AdapterEnabled=$true;DhcpEnabled=$true;NatEnabled=$true;Subnet='192.168.36.0';SubnetMask='';Gateway='192.168.36.2'},
        [pscustomobject][ordered]@{Id='VMnet19';Configured=$false;AdapterEnabled=$false;DhcpEnabled=$false;NatEnabled=$false;Subnet='';SubnetMask='';Gateway=''}
    )
}
function Read-VMnetInventory { return $script:fixtureInventory }
function Reset-MultiFixture {
    $script:fixtureInventory=@(New-Inventory)
    [IO.File]::WriteAllText((Join-Path $multiFixture 'vmnetnat.conf'),$nat)
    [IO.File]::WriteAllText((Join-Path $multiFixture 'vmnetdhcp.conf'),$dhcp)
}
try {
    Test-Case 'Inventory placeholders and bridges are skipped' {
        Reset-MultiFixture; $snapshot=Read-NetworkFiles $multiFixture
        Assert-Equal 2 @($snapshot.Networks | Where-Object { $_.Disposition -eq 'Ready' }).Count
        Assert-Equal 2 @($snapshot.Networks | Where-Object { $_.Disposition -eq 'Skipped' }).Count
    }
    Test-Case 'VMnet1-only edit leaves the VMnet8 fingerprint unchanged' {
        Reset-MultiFixture; $baseline=New-ConfigBaseline (Read-NetworkFiles $multiFixture)
        [IO.File]::WriteAllText((Join-Path $multiFixture 'vmnetdhcp.conf'),$dhcp.Replace('192.168.93.','192.168.94.'))
        $script:fixtureInventory[1].Subnet='192.168.94.0'
        $changed=@(Get-ChangedNetworks (Read-NetworkFiles $multiFixture) $baseline)
        Assert-Equal 1 $changed.Count; Assert-Equal 'VMnet1' $changed[0].Id
    }
    Test-Case 'NAT forwarding-only edit does not schedule a host-address repair' {
        Reset-MultiFixture; $baseline=New-ConfigBaseline (Read-NetworkFiles $multiFixture)
        [IO.File]::WriteAllText((Join-Path $multiFixture 'vmnetnat.conf'),$nat.Replace('2222','3333'))
        Assert-Equal 0 @(Get-ChangedNetworks (Read-NetworkFiles $multiFixture) $baseline).Count
    }
    Test-Case 'Registry-only host-adapter opt-out is detected and skipped' {
        Reset-MultiFixture; $baseline=New-ConfigBaseline (Read-NetworkFiles $multiFixture)
        $script:fixtureInventory[1].AdapterEnabled=$false
        $changed=@(Get-ChangedNetworks (Read-NetworkFiles $multiFixture) $baseline)
        Assert-Equal 1 $changed.Count; Assert-Equal 'Skipped' $changed[0].Disposition
    }
    Test-Case 'DHCP-off networks are reported without inventing a host address or mask' {
        Reset-MultiFixture; $script:fixtureInventory[1].DhcpEnabled=$false
        $snapshot=Read-NetworkFiles $multiFixture
        Assert-Equal 'Skipped' $snapshot.Networks[1].Disposition
        Assert-Equal $false ([bool]$snapshot.Networks[1].PSObject.Properties['HostIP'])
    }
    Test-Case 'One malformed host reservation does not block a valid sibling' {
        Reset-MultiFixture
        [IO.File]::WriteAllText((Join-Path $multiFixture 'vmnetdhcp.conf'),$dhcp+"`nhost VMnet1 { fixed-address 192.168.93.1; }")
        $snapshot=Read-NetworkFiles $multiFixture
        Assert-Equal 'Blocked' $snapshot.Networks[1].Disposition
        Assert-Equal 'Ready' $snapshot.Networks[2].Disposition
    }
    Test-Case 'Broken NAT config does not block host-only synchronization' {
        Reset-MultiFixture; [IO.File]::WriteAllText((Join-Path $multiFixture 'vmnetnat.conf'),'incomplete')
        $snapshot=Read-NetworkFiles $multiFixture
        Assert-Equal 'Ready' $snapshot.Networks[1].Disposition
        Assert-Equal 'Blocked' $snapshot.Networks[2].Disposition
    }
    Test-Case 'Registry and file disagreement blocks mutation' {
        Reset-MultiFixture; $script:fixtureInventory[1].Subnet='192.168.99.0'
        Assert-Equal 'Blocked' (Read-NetworkFiles $multiFixture).Networks[1].Disposition
    }
    Test-Case 'Registry mask inconsistent with DHCP is blocked while valid sibling remains ready' {
        Reset-MultiFixture; $script:fixtureInventory[1].SubnetMask='255.255.254.0'
        $snapshot=Read-NetworkFiles $multiFixture
        Assert-Equal 'Blocked' $snapshot.Networks[1].Disposition
        Assert-Equal 'Registry and DHCP subnet masks disagree; configuration may still be changing.' $snapshot.Networks[1].Reason
        Assert-Equal 'Ready' $snapshot.Networks[2].Disposition
    }
    Test-Case 'Mask-only registry edit is detected and a consistent explicit mask is accepted' {
        Reset-MultiFixture; $baseline=New-ConfigBaseline (Read-NetworkFiles $multiFixture)
        $script:fixtureInventory[1].SubnetMask='255.255.255.0'
        $changed=@(Get-ChangedNetworks (Read-NetworkFiles $multiFixture) $baseline)
        Assert-Equal 1 $changed.Count; Assert-Equal 'VMnet1' $changed[0].Id
        Assert-Equal 'Ready' $changed[0].Disposition
    }
    Test-Case 'Noncontiguous registry mask is rejected before inspecting the adapter' {
        Reset-MultiFixture; $script:fixtureInventory[1].SubnetMask='255.0.255.0'
        Assert-Equal 'Blocked' (Read-NetworkFiles $multiFixture).Networks[1].Disposition
    }
    Test-Case 'Overlapping VMnet subnets are blocked' {
        Reset-MultiFixture; $script:fixtureInventory[1].Subnet='192.168.36.0'
        $overlap=[regex]::Replace($dhcp,'(?s)subnet 192\.168\.93\.0.*?\}', '').Replace('192.168.93.1','192.168.36.10')
        [IO.File]::WriteAllText((Join-Path $multiFixture 'vmnetdhcp.conf'),$overlap)
        $snapshot=Read-NetworkFiles $multiFixture
        Assert-Equal 2 @($snapshot.Networks | Where-Object { $_.Disposition -eq 'Blocked' }).Count
        Assert-Equal $true $snapshot.Networks[1].Reason.StartsWith('Overlapping configured subnets:')
    }
    Test-Case 'VMware rewriting line endings and indentation does not select unchanged networks' {
        Reset-MultiFixture; $baseline=New-ConfigBaseline (Read-NetworkFiles $multiFixture)
        foreach ($file in @('vmnetdhcp.conf','vmnetnat.conf')) {
            $path=Join-Path $multiFixture $file
            $text=[IO.File]::ReadAllText($path).Replace("`r`n","`n")
            $text=[regex]::Replace($text,'(?m)^[ \t]+','        ')
            [IO.File]::WriteAllText($path,$text)
        }
        Assert-Equal 0 @(Get-ChangedNetworks (Read-NetworkFiles $multiFixture) $baseline).Count
    }
    Test-Case 'Removed networks are reported as skipped' {
        Reset-MultiFixture; $baseline=New-ConfigBaseline (Read-NetworkFiles $multiFixture)
        $script:fixtureInventory=@($script:fixtureInventory | Where-Object { $_.Id -ne 'VMnet1' })
        $changed=@(Get-ChangedNetworks (Read-NetworkFiles $multiFixture) $baseline)
        Assert-Equal 1 $changed.Count; Assert-Equal 'Skipped' $changed[0].Disposition
    }
    Test-Case 'Atomic baseline can be replaced repeatedly under Windows PowerShell 5.1' {
        Reset-MultiFixture; $snapshot=Read-NetworkFiles $multiFixture
        $path=Join-Path $multiFixture 'baseline.json'
        Write-JsonAtomic $path (New-ConfigBaseline $snapshot)
        Write-JsonAtomic $path (New-ConfigBaseline $snapshot)
        $baseline=[IO.File]::ReadAllText($path) | ConvertFrom-Json
        Assert-Equal 0 @(Get-ChangedNetworks $snapshot $baseline).Count
    }
    Test-Case 'Invalid baseline identities and duplicate networks are rejected' {
        $path=Join-Path $multiFixture 'invalid.json'
        Write-JsonAtomic $path ([pscustomobject]@{Version=2;FingerprintVersion=3;Networks=@([pscustomobject]@{Id='PhysicalEthernet';Fingerprint=(Get-TextHash 'test')})})
        Assert-Throws { Read-ValidBaseline $path }
        $entry=[pscustomobject]@{Id='VMnet1';Fingerprint=(Get-TextHash 'test')}
        Write-JsonAtomic $path ([pscustomobject]@{Version=2;FingerprintVersion=3;Networks=@($entry,$entry)})
        Assert-Throws { Read-ValidBaseline $path }
    }
} finally {
    $resolved=[IO.Path]::GetFullPath($multiFixture)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'vmnet-multi-tests-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "Passed $script:passed tests including multi-network parsing and registry event filters."
