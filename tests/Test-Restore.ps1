$ErrorActionPreference='Stop'
# Synthetic fixtures in a temp folder only. Every network command Restore uses is mocked below; anything missed throws.
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$Root=$TestRoot
. (Join-Path $PSScriptRoot '..\src\powershell\network-core.ps1')
Use-TestRoot
function New-Fixture([bool]$StaticDns) {
    [pscustomobject]@{
        Version=2;Status='Applied';MachineGuid='synthetic-test-machine';RouteAdded=$true;Gateway='192.168.1.1'
        Wifi=[pscustomobject]@{Guid='{11111111-1111-1111-1111-111111111111}';Metric=25;AutomaticMetric='Enabled';IgnoreDefaultRoutes='Disabled'}
        Ethernet=[pscustomobject]@{Guid='{22222222-2222-2222-2222-222222222222}';Metric=35;AutomaticMetric='Disabled';IgnoreDefaultRoutes='Disabled';StaticDns=$StaticDns;Dns=@('192.0.2.53')}
        RemovedRoutes=@(
            [pscustomobject]@{Prefix='0.0.0.0/0';NextHop='192.168.1.1';Metric=5;Persistent=$false}
            [pscustomobject]@{Prefix='0.0.0.0/1';NextHop='192.168.1.1';Metric=6;Persistent=$true}
            [pscustomobject]@{Prefix='128.0.0.0/1';NextHop='192.168.1.1';Metric=7;Persistent=$false}
            [pscustomobject]@{Prefix='203.0.113.0/24';NextHop='192.168.1.1';Metric=8;Persistent=$true}
        )
        Profiles=@([pscustomobject]@{Name='Domain';Enabled='True'},[pscustomobject]@{Name='Private';Enabled='False'},[pscustomobject]@{Name='Public';Enabled='True'})
        AdditionalRuleGroups=@('CodexStrictSplit20261016')
    }
}
function Get-ItemProperty($Path) {[pscustomobject]@{MachineGuid='synthetic-test-machine'}}
$script:ops=New-Object 'System.Collections.Generic.List[object]'
function Record-Test($name,$data) {$script:ops.Add([pscustomobject]@{Name=$name;Data=$data}) | Out-Null}
# The state names adapters only by GUID; the interface numbers below exist only in this test.
function Adapter-ByGuid($guid) {
    if (([guid]$guid) -eq [guid]'{22222222-2222-2222-2222-222222222222}') {return [pscustomobject]@{ifIndex=8101;Name='test-ethernet'}}
    if (([guid]$guid) -eq [guid]'{11111111-1111-1111-1111-111111111111}') {return [pscustomobject]@{ifIndex=8102;Name='test-wifi'}}
    throw 'Unknown adapter identity'
}
function Get-NetRoute($PolicyStore,$InterfaceIndex,$DestinationPrefix,$ErrorAction) {
    if ($DestinationPrefix -eq '192.168.0.0/16') {return [pscustomobject]@{NextHop='192.168.1.1';InterfaceIndex=$InterfaceIndex;PolicyStore=$PolicyStore}}
}
function Remove-NetRoute {param([Parameter(ValueFromPipeline)]$InputObject,[switch]$Confirm) process {Record-Test 'RemoveRoute' $InputObject}}
function New-NetRoute($PolicyStore,$InterfaceIndex,$DestinationPrefix,$NextHop,$RouteMetric) {Record-Test 'NewRoute' ([pscustomobject]@{PolicyStore=$PolicyStore;InterfaceIndex=$InterfaceIndex;DestinationPrefix=$DestinationPrefix;NextHop=$NextHop;RouteMetric=$RouteMetric})}
function Set-NetIPInterface($InterfaceIndex,$AddressFamily,$AutomaticMetric,$InterfaceMetric,$IgnoreDefaultRoutes) {Record-Test 'SetInterface' ([pscustomobject]$PSBoundParameters)}
function Set-DnsClientServerAddress($InterfaceIndex,$ServerAddresses,[switch]$ResetServerAddresses) {Record-Test 'SetDNS' ([pscustomobject]@{InterfaceIndex=$InterfaceIndex;ServerAddresses=$ServerAddresses;Reset=[bool]$ResetServerAddresses})}
function Clear-DnsClientCache {Record-Test 'ClearDNS' $null}
function Get-NetFirewallRule($Group,$ErrorAction) {return [pscustomobject]@{Group=$Group}}
function Remove-NetFirewallRule {param([Parameter(ValueFromPipeline)]$InputObject) process {Record-Test 'RemoveFirewall' $InputObject}}
function Set-NetFirewallProfile($Profile,$Enabled) {Record-Test 'SetProfile' ([pscustomobject]@{Profile=$Profile;Enabled=$Enabled})}

try {
    # 1. Static DNS, mixed persistent and active routes.
    Save-State (New-Fixture $true)
    Restore
    $saved=Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($saved.Status -eq 'Restored') 'Restore did not persist completion'
    Assert (Test-Path ($StateFile+'.previous')) 'Atomic save did not keep the previous state'
    Assert (-not (Test-Path ($StateFile+'.tmp'))) 'Temporary state file left behind'
    $removed=@($script:ops | Where-Object Name -eq RemoveRoute)
    Assert ($removed.Count -ge 1 -and @($removed | Where-Object {$_.Data.NextHop -ne '192.168.1.1'}).Count -eq 0) 'The 192.168.0.0/16 route via the saved gateway was not removed'
    $routes=@($script:ops | Where-Object Name -eq NewRoute)
    Assert ($routes.Count -eq 4) 'Not every removed route was restored'
    Assert (@($routes | Where-Object {$_.Data.InterfaceIndex -ne 8101}).Count -eq 0) 'Routes were not restored to the GUID-resolved Ethernet adapter'
    foreach ($r in (New-Fixture $true).RemovedRoutes) {
        $op=@($routes | Where-Object {$_.Data.DestinationPrefix -eq $r.Prefix})[0]
        Assert ($op.Data.RouteMetric -eq $r.Metric) ('Wrong metric restored for '+$r.Prefix)
        if ($r.Persistent) {Assert (-not $op.Data.PolicyStore) ('Persistent route '+$r.Prefix+' must be recreated in both stores')}
        else {Assert ($op.Data.PolicyStore -eq 'ActiveStore') ('Active-only route '+$r.Prefix+' must not become persistent')}
    }
    $ifaces=@($script:ops | Where-Object Name -eq SetInterface)
    Assert ($ifaces | Where-Object {$_.Data.InterfaceIndex -eq 8101 -and $_.Data.IgnoreDefaultRoutes -eq 'Disabled' -and $_.Data.InterfaceMetric -eq 35}) 'Ethernet metric / default route preference not restored'
    Assert (-not ($ifaces | Where-Object {$_.Data.InterfaceIndex -eq 8101 -and $_.Data.AutomaticMetric -eq 'Enabled'})) 'Ethernet automatic metric was enabled although it was disabled before'
    Assert ($ifaces | Where-Object {$_.Data.InterfaceIndex -eq 8102 -and $_.Data.AutomaticMetric -eq 'Enabled'}) 'Wi-Fi automatic metric was not restored'
    $dns=@($script:ops | Where-Object Name -eq SetDNS)
    Assert ($dns.Count -eq 1 -and $dns[0].Data.InterfaceIndex -eq 8101 -and -not $dns[0].Data.Reset -and $dns[0].Data.ServerAddresses -contains '192.0.2.53') 'Original static DNS not restored'
    $groups=@($script:ops | Where-Object Name -eq RemoveFirewall | ForEach-Object {$_.Data.Group})
    Assert ($groups -contains 'CodexStrictSplit20261016' -and $groups -contains 'WifiPublicWiredLAN-v2') 'Not every guard rule group was removed'
    $profiles=@($script:ops | Where-Object Name -eq SetProfile)
    Assert (@($profiles | Where-Object {$_.Data.Profile -eq 'Private' -and $_.Data.Enabled -eq 'False'}).Count -eq 1) 'Firewall profile state not restored'

    # 2. DHCP-provided DNS is reset rather than pinned.
    $script:ops.Clear(); Remove-Item -LiteralPath $StateFile; Save-State (New-Fixture $false)
    Restore
    $dns=@($script:ops | Where-Object Name -eq SetDNS)
    Assert ($dns.Count -eq 1 -and $dns[0].Data.Reset) 'DHCP DNS was not reset'

    # 3. A second restore changes nothing.
    $script:ops.Clear()
    Restore
    Assert ($script:ops.Count -eq 0) 'Restoring an already restored state changed settings'

    # 4. A backup from another Windows installation is refused before any change.
    $other=New-Fixture $true; $other.MachineGuid='wrong-windows-installation'; Save-State $other
    $script:ops.Clear(); $refused=$false
    try {Restore} catch {$refused=$true}
    Assert ($refused -and $script:ops.Count -eq 0) 'Cross-machine restore was not refused before changes'

    # 5. An adapter that cannot be found by GUID stops the restore before any change.
    $missing=New-Fixture $true; $missing.Ethernet.Guid='{99999999-9999-9999-9999-999999999999}'; Save-State $missing
    $script:ops.Clear(); $refused=$false
    try {Restore} catch {$refused=$true}
    Assert ($refused -and $script:ops.Count -eq 0) 'Restore guessed a replacement adapter'
    Write-Output 'PASS Test-Restore: route stores and metrics, DNS (static and DHCP), metrics, rule groups, profiles, atomic state, repeat restore, cross-machine and missing-adapter refusal.'
} finally {Remove-TestRoot}
