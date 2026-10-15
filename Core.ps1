Set-StrictMode -Version Latest

function ConvertTo-IPv4Number([string]$Address) {
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Invalid IPv4: $Address" }
    $parts = @($Address.Split('.') | ForEach-Object { [int]$_ })
    if (@($parts | Where-Object { $_ -gt 255 }).Count) { throw "Invalid IPv4: $Address" }
    return [uint64]($parts[0] * 16777216L + $parts[1] * 65536L + $parts[2] * 256L + $parts[3])
}

function ConvertFrom-IPv4Number([uint64]$Number) {
    return '{0}.{1}.{2}.{3}' -f (($Number -shr 24) -band 255), (($Number -shr 16) -band 255), (($Number -shr 8) -band 255), ($Number -band 255)
}

function Get-IPv4Mask([int]$Prefix) {
    if ($Prefix -lt 1 -or $Prefix -gt 30) { throw 'Only IPv4 prefixes /1 through /30 are supported.' }
    return [uint64](4294967296L - [math]::Pow(2, 32 - $Prefix))
}

function ConvertFrom-IPv4Mask([string]$Mask) {
    $number = ConvertTo-IPv4Number $Mask
    for ($prefix = 1; $prefix -le 30; $prefix++) {
        if ($number -eq (Get-IPv4Mask $prefix)) { return $prefix }
    }
    throw "Unsupported or noncontiguous subnet mask: $Mask"
}

function Get-TextHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-DhcpBlocks([string]$Text, [string]$HeaderPattern) {
    foreach ($match in [regex]::Matches($Text, $HeaderPattern, 'Multiline,IgnoreCase')) {
        $start = $match.Index + $match.Length
        $depth = 1
        $end = $start
        while ($end -lt $Text.Length -and $depth -gt 0) {
            if ($Text[$end] -eq '{') { $depth++ }
            if ($Text[$end] -eq '}') { $depth-- }
            $end++
        }
        if ($depth -ne 0) { throw 'DHCP configuration is incomplete (unclosed block).' }
        [pscustomobject]@{ Header = $match; Body = $Text.Substring($start, $end - $start - 1) }
    }
}

function Get-UniqueMatch([string]$Text, [string]$Pattern, [string]$Label) {
    $found = [regex]::Matches($Text, $Pattern, 'Multiline,IgnoreCase')
    if ($found.Count -ne 1) { throw "Expected exactly one $Label; found $($found.Count)." }
    return $found[0]
}

function Read-DesiredNetwork([string]$NatText, [string]$DhcpText, [string]$Id = 'VMnet8', [bool]$IsNat = $true) {
    $nat = [regex]::Replace($NatText, '(?m)[#;].*$', '')
    $dhcp = [regex]::Replace($DhcpText, '(?m)#.*$', '')
    if ($Id -notmatch '^VMnet(?:[0-9]|1[0-9])$') { throw 'Unsupported VMnet identifier.' }
    $hosts = @(Get-DhcpBlocks $dhcp ('^\s*host\s+' + [regex]::Escape($Id) + '\s*\{'))
    if ($hosts.Count -ne 1) { throw "Expected exactly one DHCP host $Id block." }
    $hostMatch = Get-UniqueMatch $hosts[0].Body '^\s*fixed-address\s+([\d.]+)\s*;' "$Id host address"
    $macMatch = Get-UniqueMatch $hosts[0].Body '^\s*hardware\s+ethernet\s+([0-9a-f:]+)\s*;' "$Id host MAC"
    $hostIp = $hostMatch.Groups[1].Value
    $hostNumber = ConvertTo-IPv4Number $hostIp
    $mac = $macMatch.Groups[1].Value.Replace(':', '').ToUpperInvariant()
    if ($mac -notmatch '^[0-9A-F]{12}$') { throw 'Invalid DHCP host MAC.' }
    $subnets = @(Get-DhcpBlocks $dhcp '^\s*subnet\s+([\d.]+)\s+netmask\s+([\d.]+)\s*\{')
    $matching = @($subnets | Where-Object {
        $subnetMask = ConvertTo-IPv4Number $_.Header.Groups[2].Value
        ((ConvertTo-IPv4Number $_.Header.Groups[1].Value) -eq ($hostNumber -band $subnetMask))
    })
    if ($matching.Count -ne 1) { throw "No unique DHCP subnet matches the $Id host." }
    $subnet = $matching[0]
    $prefix = ConvertFrom-IPv4Mask $subnet.Header.Groups[2].Value
    $mask = Get-IPv4Mask $prefix
    $networkNumber = ConvertTo-IPv4Number $subnet.Header.Groups[1].Value
    if (($networkNumber -band $mask) -ne $networkNumber) { throw 'DHCP subnet is not a network address.' }
    $broadcast = $networkNumber + (4294967295L - $mask)
    $gateway = $null; $gatewayNumber = $null
    if ($IsNat) {
        $hostSection = Get-UniqueMatch $nat '(?ms)^\s*\[host\][ \t]*\r?\n(.*?)(?=^\s*\[|\z)' 'NAT [host] section'
        $section = $hostSection.Groups[1].Value
        $gatewayMatch = Get-UniqueMatch $section '^\s*ip\s*=\s*([\d.]+)/([\d]+)\s*$' 'NAT gateway'
        $device = Get-UniqueMatch $section '^\s*device\s*=\s*(\S+)\s*$' 'NAT device'
        if ($device.Groups[1].Value -ine $Id) { throw "NAT device does not match $Id." }
        $gateway = $gatewayMatch.Groups[1].Value
        $gatewayNumber = ConvertTo-IPv4Number $gateway
        if ([int]$gatewayMatch.Groups[2].Value -ne $prefix -or ($gatewayNumber -band $mask) -ne $networkNumber) { throw 'NAT and DHCP subnet/prefix disagree.' }
        if ($gatewayNumber -le $networkNumber -or $gatewayNumber -ge $broadcast -or $gateway -eq $hostIp) { throw 'Invalid NAT gateway.' }
        $natHost = [regex]::Matches($section, '(?mi)^\s*hostIp\s*=\s*([\d.]+)\s*$')
        if ($natHost.Count -gt 1 -or ($natHost.Count -eq 1 -and $natHost[0].Groups[1].Value -ne $hostIp)) { throw 'NAT hostIp and DHCP host address disagree.' }
        $router = Get-UniqueMatch $subnet.Body '^\s*option\s+routers\s+([\d.]+)\s*;' 'DHCP router'
        if ($router.Groups[1].Value -ne $gateway) { throw 'DHCP router and NAT gateway disagree.' }
    }
    if ($hostNumber -le $networkNumber -or $hostNumber -ge $broadcast) { throw 'Host address is outside the usable DHCP subnet.' }
    $ranges = [regex]::Matches($subnet.Body, '(?mi)^\s*range\s+(?:dynamic-bootp\s+)?([\d.]+)\s+([\d.]+)\s*;')
    if ($ranges.Count -eq 0) { throw 'A DHCP pool is required by this version.' }
    foreach ($range in $ranges) {
        $first = ConvertTo-IPv4Number $range.Groups[1].Value
        $last = ConvertTo-IPv4Number $range.Groups[2].Value
        if ($first -gt $last -or $first -le $networkNumber -or $last -ge $broadcast) { throw 'Invalid DHCP pool.' }
        if (($hostNumber -ge $first -and $hostNumber -le $last) -or ($IsNat -and $gatewayNumber -ge $first -and $gatewayNumber -le $last)) {
            throw 'DHCP pool overlaps the reserved host or NAT gateway address.'
        }
    }
    return [pscustomobject]@{
        Id = $Id; Kind = $(if ($IsNat) { 'NAT' } else { 'HostOnly' }); Disposition = 'Ready'; Reason = ''
        HostIP = $hostIp; PrefixLength = $prefix; Gateway = $gateway; HostMac = $mac
        Network = "$(ConvertFrom-IPv4Number $networkNumber)/$prefix"
        # VMware rewrites CRLF/LF and indentation for untouched networks on Apply.
        # Formatting changes must not select an unrelated host adapter.
        Fingerprint = Get-TextHash (([regex]::Replace(($hosts[0].Body + $subnet.Header.Value + $subnet.Body + $(if ($IsNat) { $section } else { '' })), '\s+', ' ')).Trim())
    }
}

function Get-SyncDecision($Desired, $Actual) {
    if ($Actual.AdapterCount -ne 1) { return "Blocked: $($Desired.Id) adapter is missing or ambiguous" }
    if ($Actual.Mac -ne $Desired.HostMac) { return 'Blocked: adapter MAC differs from the VMware host reservation' }
    if ($Actual.Status -ne 'Up') { return "Blocked: $($Desired.Id) adapter is disabled or disconnected" }
    if ($Actual.DefaultRoute) { return "Blocked: $($Desired.Id) has a default route; review it manually" }
    $matching = @($Actual.Addresses | Where-Object { $_.IPAddress -eq $Desired.HostIP -and $_.PrefixLength -eq $Desired.PrefixLength -and $_.AddressState -eq 'Preferred' })
    if ($matching.Count -gt 0 -and $Actual.DirectRoute -and $Actual.ServicesRunning) { return 'Synced' }
    if (-not $Actual.DhcpEnabled) { return 'Blocked: automatic repair supports DHCP-managed host adapters only' }
    return 'Repair'
}

function Get-VMnetRegistryRoot {
    foreach ($path in @('HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.\VMnetLib\VMnetConfig', 'HKLM:\SOFTWARE\VMware, Inc.\VMnetLib\VMnetConfig')) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    throw 'VMware VMnetConfig registry key was not found; refusing to guess the configured networks.'
}

function Read-VMnetInventory {
    # Registry-provider objects can share cached handles. Disposing a Get-Item
    # result breaks later Get-Acl/Set-Acl in the same installer/worker process.
    # Own a separate native handle instead.
    $subkey = (Get-VMnetRegistryRoot) -replace '^HKLM:\\', ''
    $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($subkey)
    if ($null -eq $root) { throw 'VMware VMnetConfig registry key could not be opened.' }
    try {
        foreach ($name in @($root.GetSubKeyNames() | Sort-Object)) {
            if ($name -notmatch '^vmnet(?:[0-9]|1[0-9])$') { continue }
            $key = $root.OpenSubKey($name)
            try {
                $flags = @{}
                foreach ($part in @('Adapter','DHCP','NAT')) {
                    $child = $key.OpenSubKey($part)
                    $flags[$part] = $null
                    if ($null -ne $child) {
                        try { $flags[$part] = $child.GetValue(('Use' + $part), $null) } finally { $child.Dispose() }
                    }
                }
                $natKey = $key.OpenSubKey('NAT')
                $gateway = ''
                if ($null -ne $natKey) {
                    try { $gateway = ([string]$natKey.GetValue('GatewayIPAddress', '')).Trim([char]0).Trim() } finally { $natKey.Dispose() }
                }
                [pscustomobject][ordered]@{
                    Id = 'VMnet' + [int]$name.Substring(5)
                    Configured = ($null -ne $flags.Adapter -or $null -ne $flags.DHCP -or $null -ne $flags.NAT)
                    AdapterEnabled = ($flags.Adapter -eq 1); DhcpEnabled = ($flags.DHCP -eq 1); NatEnabled = ($flags.NAT -eq 1)
                    Subnet = ([string]$key.GetValue('IPSubnetAddress', '')).Trim([char]0).Trim()
                    SubnetMask = ([string]$key.GetValue('IPSubnetMask', '')).Trim([char]0).Trim(); Gateway = $gateway
                }
            } finally { $key.Dispose() }
        }
    } finally { $root.Dispose() }
}

function Read-NetworkFiles([string]$Directory) {
    # Registry flags distinguish configured networks from netmap.conf placeholders,
    # and preserve the editor's explicit host-adapter/DHCP opt-outs.
    $inventory = @(Read-VMnetInventory)
    $natPath = Join-Path $Directory 'vmnetnat.conf'; $dhcpPath = Join-Path $Directory 'vmnetdhcp.conf'
    $nat = if ([IO.File]::Exists($natPath)) { [IO.File]::ReadAllText($natPath) } else { '' }
    $dhcp = if ([IO.File]::Exists($dhcpPath)) { [IO.File]::ReadAllText($dhcpPath) } else { '' }
    $dhcpClean = [regex]::Replace($dhcp, '(?m)#.*$', '')
    $networks = @(
        foreach ($entry in $inventory) {
            $metadata = $entry | ConvertTo-Json -Compress
            $state = [pscustomobject]@{ Id=$entry.Id; Kind='None'; Disposition='Skipped'; Reason='Unused or bridged network'; Fingerprint=(Get-TextHash $metadata) }
            if (-not $entry.Configured) { $state; continue }
            if (-not $entry.AdapterEnabled) { $state.Reason='Host virtual adapter is not connected in VMware'; $state; continue }
            if (-not $entry.DhcpEnabled) { $state.Reason='VMware DHCP is disabled; automatic repair is unsupported'; $state; continue }
            try {
                $state = Read-DesiredNetwork $nat $dhcp $entry.Id $entry.NatEnabled
                $state.Fingerprint = Get-TextHash ($metadata + $state.Fingerprint)
                if ($entry.Subnet -ne '' -and $state.Network.Split('/')[0] -ne $entry.Subnet) { throw 'Registry and DHCP subnet disagree; configuration may still be changing.' }
                # Some VMware versions omit this value for the default /24.
                # When present it must agree with DHCP before touching an adapter.
                if ($entry.SubnetMask -ne '' -and (ConvertFrom-IPv4Mask $entry.SubnetMask) -ne $state.PrefixLength) { throw 'Registry and DHCP subnet masks disagree; configuration may still be changing.' }
                if ($entry.NatEnabled -and $entry.Gateway -ne '' -and $entry.Gateway -ne $state.Gateway) { throw 'Registry and NAT gateway disagree.' }
            } catch {
                $problem = $_.Exception.Message
                # Keep one malformed network from suppressing a valid sibling.
                # Scope the error fingerprint to this VMnet's source blocks.
                $evidence = ''
                try {
                    $evidence = (@(Get-DhcpBlocks $dhcpClean ('^\s*host\s+' + [regex]::Escape($entry.Id) + '\s*\{')) | ForEach-Object { $_.Header.Value + $_.Body }) -join "`n"
                    $evidence += (@(Get-DhcpBlocks $dhcpClean '^\s*subnet\s+([\d.]+)\s+netmask\s+([\d.]+)\s*\{') | Where-Object { $_.Header.Groups[1].Value -eq $entry.Subnet } | ForEach-Object { $_.Header.Value + $_.Body }) -join "`n"
                } catch { $evidence = $dhcpClean }
                if ($entry.NatEnabled) { $evidence += $nat }
                $state = [pscustomobject]@{ Id=$entry.Id; Kind=$(if ($entry.NatEnabled) {'NAT'} else {'HostOnly'}); Disposition='Blocked'; Reason=$problem; Fingerprint=(Get-TextHash ($metadata + $evidence)) }
            }
            $state
        }
    )
    # Overlapping configured subnets can route traffic to the wrong VMnet.
    $ready = @($networks | Where-Object { $_.Disposition -eq 'Ready' })
    for ($i=0; $i -lt $ready.Count; $i++) {
        for ($j=$i+1; $j -lt $ready.Count; $j++) {
            $a = $ready[$i]; $b = $ready[$j]
            $mask = Get-IPv4Mask ([math]::Min($a.PrefixLength,$b.PrefixLength))
            if (((ConvertTo-IPv4Number $a.HostIP) -band $mask) -eq ((ConvertTo-IPv4Number $b.HostIP) -band $mask)) {
                foreach ($item in @($a,$b)) { $item.Disposition='Blocked'; $item.Reason="Overlapping configured subnets: $($a.Id), $($b.Id)" }
            }
        }
    }
    return [pscustomobject]@{ Networks=$networks; Fingerprint=(Get-TextHash (($networks | ConvertTo-Json -Depth 5 -Compress))) }
}

function New-ConfigBaseline($Snapshot) {
    return [pscustomobject]@{ Version=2; FingerprintVersion=3; Networks=@($Snapshot.Networks | Select-Object Id,Fingerprint) }
}

function Get-ChangedNetworks($Snapshot, $Baseline) {
    foreach ($network in $Snapshot.Networks) {
        $old = @($Baseline.Networks | Where-Object { $_.Id -eq $network.Id })
        if ($old.Count -ne 1 -or $old[0].Fingerprint -ne $network.Fingerprint) { $network }
    }
    foreach ($old in $Baseline.Networks) {
        if (@($Snapshot.Networks | Where-Object { $_.Id -eq $old.Id }).Count -eq 0) {
            [pscustomobject]@{ Id=$old.Id; Kind='None'; Disposition='Skipped'; Reason='Network removed from VMware'; Fingerprint='Removed' }
        }
    }
}

function Write-JsonAtomic([string]$Path, $Value) {
    $temporary = $Path + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Read-ValidBaseline([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw 'Configuration baseline is missing. Reinstall to initialize it without repairing adapters.' }
    $baseline = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if (-not $baseline.PSObject.Properties['FingerprintVersion'] -or $baseline.FingerprintVersion -ne 3) { throw 'Configuration fingerprint format changed. Reinstall to snapshot it without repairing adapters.' }
    if ($baseline.Version -ne 2 -or -not $baseline.PSObject.Properties['Networks'] -or @($baseline.Networks).Count -gt 20) { throw 'Invalid configuration baseline. Reinstall to recover.' }
    $seen = @{}
    foreach ($entry in $baseline.Networks) {
        if ($entry.Id -notmatch '^VMnet(?:[0-9]|1[0-9])$' -or $entry.Fingerprint -notmatch '^[0-9a-f]{64}$' -or $seen.ContainsKey($entry.Id)) { throw 'Invalid network entry in configuration baseline.' }
        $seen[$entry.Id]=$true
    }
    return $baseline
}
