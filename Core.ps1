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

function Read-DesiredNetwork([string]$NatText, [string]$DhcpText) {
    $nat = [regex]::Replace($NatText, '(?m)[#;].*$', '')
    $dhcp = [regex]::Replace($DhcpText, '(?m)#.*$', '')
    $hostSection = Get-UniqueMatch $nat '(?ms)^\s*\[host\][ \t]*\r?\n(.*?)(?=^\s*\[|\z)' 'NAT [host] section'
    $section = $hostSection.Groups[1].Value
    $gatewayMatch = Get-UniqueMatch $section '^\s*ip\s*=\s*([\d.]+)/([\d]+)\s*$' 'NAT gateway'
    $device = Get-UniqueMatch $section '^\s*device\s*=\s*(\S+)\s*$' 'NAT device'
    if ($device.Groups[1].Value -ine 'vmnet8') { throw 'This configuration is not for VMnet8.' }
    $gateway = $gatewayMatch.Groups[1].Value
    $prefix = [int]$gatewayMatch.Groups[2].Value
    $mask = Get-IPv4Mask $prefix
    $networkNumber = (ConvertTo-IPv4Number $gateway) -band $mask
    $broadcast = $networkNumber + (4294967295L - $mask)
    $hosts = @(Get-DhcpBlocks $dhcp '^\s*host\s+VMnet8\s*\{')
    if ($hosts.Count -ne 1) { throw 'Expected exactly one DHCP host VMnet8 block.' }
    $hostMatch = Get-UniqueMatch $hosts[0].Body '^\s*fixed-address\s+([\d.]+)\s*;' 'VMnet8 host address'
    $macMatch = Get-UniqueMatch $hosts[0].Body '^\s*hardware\s+ethernet\s+([0-9a-f:]+)\s*;' 'VMnet8 host MAC'
    $hostIp = $hostMatch.Groups[1].Value
    $hostNumber = ConvertTo-IPv4Number $hostIp
    $mac = $macMatch.Groups[1].Value.Replace(':', '').ToUpperInvariant()
    if ($mac -notmatch '^[0-9A-F]{12}$') { throw 'Invalid DHCP host MAC.' }
    if ($hostNumber -le $networkNumber -or $hostNumber -ge $broadcast -or $hostIp -eq $gateway) {
        throw 'Host address is outside the usable NAT subnet, or equals the gateway.'
    }
    $gatewayNumber = ConvertTo-IPv4Number $gateway
    if ($gatewayNumber -le $networkNumber -or $gatewayNumber -ge $broadcast) { throw 'Invalid NAT gateway.' }
    $natHost = [regex]::Matches($section, '(?mi)^\s*hostIp\s*=\s*([\d.]+)\s*$')
    if ($natHost.Count -gt 1 -or ($natHost.Count -eq 1 -and $natHost[0].Groups[1].Value -ne $hostIp)) {
        throw 'NAT hostIp and DHCP host address disagree; configuration may still be changing.'
    }
    $subnets = @(Get-DhcpBlocks $dhcp '^\s*subnet\s+([\d.]+)\s+netmask\s+([\d.]+)\s*\{')
    $matching = @($subnets | Where-Object {
        $subnetMask = ConvertTo-IPv4Number $_.Header.Groups[2].Value
        ((ConvertTo-IPv4Number $_.Header.Groups[1].Value) -eq ($hostNumber -band $subnetMask))
    })
    if ($matching.Count -ne 1) { throw 'No unique DHCP subnet matches the VMnet8 host.' }
    $subnet = $matching[0]
    if ((ConvertFrom-IPv4Mask $subnet.Header.Groups[2].Value) -ne $prefix -or
        (ConvertTo-IPv4Number $subnet.Header.Groups[1].Value) -ne $networkNumber) {
        throw 'NAT and DHCP subnet/prefix disagree.'
    }
    $router = Get-UniqueMatch $subnet.Body '^\s*option\s+routers\s+([\d.]+)\s*;' 'DHCP router'
    if ($router.Groups[1].Value -ne $gateway) { throw 'DHCP router and NAT gateway disagree.' }
    $ranges = [regex]::Matches($subnet.Body, '(?mi)^\s*range\s+(?:dynamic-bootp\s+)?([\d.]+)\s+([\d.]+)\s*;')
    if ($ranges.Count -eq 0) { throw 'A DHCP pool is required by this version.' }
    foreach ($range in $ranges) {
        $first = ConvertTo-IPv4Number $range.Groups[1].Value
        $last = ConvertTo-IPv4Number $range.Groups[2].Value
        if ($first -gt $last -or $first -le $networkNumber -or $last -ge $broadcast) { throw 'Invalid DHCP pool.' }
        if (($hostNumber -ge $first -and $hostNumber -le $last) -or ($gatewayNumber -ge $first -and $gatewayNumber -le $last)) {
            throw 'DHCP pool overlaps the reserved host or NAT gateway address.'
        }
    }
    return [pscustomobject]@{
        HostIP = $hostIp; PrefixLength = $prefix; Gateway = $gateway; HostMac = $mac
        Network = "$(ConvertFrom-IPv4Number $networkNumber)/$prefix"
        Fingerprint = Get-TextHash ($NatText + "`n---DHCP---`n" + $DhcpText)
    }
}

function Read-NetworkFiles([string]$Directory) {
    $nat = [IO.File]::ReadAllText((Join-Path $Directory 'vmnetnat.conf'))
    $dhcp = [IO.File]::ReadAllText((Join-Path $Directory 'vmnetdhcp.conf'))
    return Read-DesiredNetwork $nat $dhcp
}

function Get-SyncDecision($Desired, $Actual) {
    if ($Actual.AdapterCount -ne 1) { return 'Blocked: VMnet8 adapter is missing or ambiguous' }
    if ($Actual.Mac -ne $Desired.HostMac) { return 'Blocked: adapter MAC differs from the VMware host reservation' }
    if ($Actual.Status -ne 'Up') { return 'Blocked: VMnet8 adapter is disabled or disconnected' }
    if ($Actual.DefaultRoute) { return 'Blocked: VMnet8 has a default route; review it manually' }
    $matching = @($Actual.Addresses | Where-Object { $_.IPAddress -eq $Desired.HostIP -and $_.PrefixLength -eq $Desired.PrefixLength -and $_.AddressState -eq 'Preferred' })
    if ($matching.Count -gt 0 -and $Actual.DirectRoute -and $Actual.ServicesRunning) { return 'Synced' }
    if (-not $Actual.DhcpEnabled) { return 'Blocked: automatic repair supports DHCP-managed host adapters only' }
    return 'Repair'
}
