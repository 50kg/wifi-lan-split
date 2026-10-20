$ErrorActionPreference='Stop'
# Simulates Setup against fictional adapters. Every network command is mocked; anything missed throws.
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$Root=$TestRoot
. (Join-Path $PSScriptRoot '..\src\powershell\network-core.ps1')
Use-TestRoot
$script:ops=New-Object 'System.Collections.Generic.List[object]'
function Record-Test($name,$data) {$script:ops.Add([pscustomobject]@{Name=$name;Data=$data}) | Out-Null}
function Index-Of($name) {for ($i=0; $i -lt $script:ops.Count; $i++) {if ($script:ops[$i].Name -eq $name) {return $i}}; -1}
function LastIndex-Of($name) {$last=-1; for ($i=0; $i -lt $script:ops.Count; $i++) {if ($script:ops[$i].Name -eq $name) {$last=$i}}; $last}

$wifiGuid='{11111111-1111-1111-1111-111111111111}'; $ethGuid='{22222222-2222-2222-2222-222222222222}'
function Reset-World([string]$HotspotIp='192.168.43.20',[switch]$ExtraAdapter) {
    $script:ops.Clear(); $script:rules=@(); $script:profileOn=@{Domain='True';Private='False';Public='True'}
    $script:adapters=@(
        [pscustomobject]@{Name='WLAN';InterfaceDescription='Wireless';MediaType='Native 802.11';Status='Up';ifIndex=11;InterfaceGuid=$wifiGuid;Physical=$true},
        [pscustomobject]@{Name='以太网';InterfaceDescription='Ethernet';MediaType='802.3';Status='Up';ifIndex=12;InterfaceGuid=$ethGuid;Physical=$true}
    )
    if ($ExtraAdapter) {$script:adapters+=[pscustomobject]@{Name='vEthernet (WSL)';InterfaceDescription='Hyper-V';MediaType='802.3';Status='Up';ifIndex=13;InterfaceGuid='{33333333-3333-3333-3333-333333333333}';Physical=$false}}
    $script:hotspotIp=$HotspotIp
    if (Test-Path -LiteralPath $StateFile) {Remove-Item -LiteralPath $StateFile -Force}
    Get-ChildItem -LiteralPath $Root -Directory | Remove-Item -Recurse -Force
}
function Show-Check {}
function Get-NetAdapter([switch]$Physical) {if ($Physical) {$script:adapters | Where-Object Physical} else {$script:adapters}}
function Get-Service($Name) {[pscustomobject]@{Name=$Name;Status='Running'}}
function Get-ItemProperty($Path) {if ($Path -like '*Cryptography*') {[pscustomobject]@{MachineGuid='synthetic-test-machine'}} else {[pscustomobject]@{NameServer=''}}}
function Get-NetIPAddress($InterfaceIndex,$AddressFamily,$ErrorAction) {
    if ($InterfaceIndex -eq 11) {[pscustomobject]@{IPAddress=$script:hotspotIp;PrefixLength=24;AddressState='Preferred'}}
    elseif ($InterfaceIndex -eq 12) {[pscustomobject]@{IPAddress='192.168.1.23';PrefixLength=24;AddressState='Preferred'}}
}
function Get-NetIPInterface($InterfaceIndex,$AddressFamily) {[pscustomobject]@{Dhcp='Enabled';InterfaceMetric=25;AutomaticMetric='Enabled';IgnoreDefaultRoutes='Disabled'}}
function Get-DnsClientServerAddress($InterfaceIndex,$AddressFamily) {if ($InterfaceIndex -eq 11) {[pscustomobject]@{ServerAddresses=@('192.168.43.1')}} else {[pscustomobject]@{ServerAddresses=@('192.168.1.1')}}}
function Get-NetRoute($PolicyStore,$InterfaceIndex,$AddressFamily,$DestinationPrefix,$ErrorAction) {
    $all=@(
        [pscustomobject]@{Store='Active';InterfaceIndex=11;DestinationPrefix='0.0.0.0/0';NextHop='192.168.43.1';RouteMetric=0},
        [pscustomobject]@{Store='Active';InterfaceIndex=12;DestinationPrefix='0.0.0.0/0';NextHop='192.168.1.1';RouteMetric=0},
        [pscustomobject]@{Store='Active';InterfaceIndex=12;DestinationPrefix='192.168.1.0/24';NextHop='0.0.0.0';RouteMetric=256},
        [pscustomobject]@{Store='Active';InterfaceIndex=12;DestinationPrefix='203.0.113.0/24';NextHop='192.168.1.1';RouteMetric=20},
        [pscustomobject]@{Store='Persistent';InterfaceIndex=12;DestinationPrefix='203.0.113.0/24';NextHop='192.168.1.1';RouteMetric=20}
    )
    $store=if ($PolicyStore -eq 'PersistentStore') {'Persistent'} else {'Active'}
    $all | Where-Object {$_.Store -eq $store -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) -and (-not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix)}
}
function Invoke-MockNetsh {Record-Test 'Backup' $args; Set-Content -LiteralPath $args[2] 'synthetic firewall export'; $global:LASTEXITCODE=0}
$NetshExe='Invoke-MockNetsh'
function Get-NetFirewallProfile($PolicyStore,$Profile) {
    foreach ($n in 'Domain','Private','Public') {[pscustomobject]@{Name=$n;Enabled=$script:profileOn[$n];AllowLocalFirewallRules='NotConfigured'}}
}
function Set-NetFirewallProfile($Profile,$Enabled) {Record-Test 'SetProfile' ([pscustomobject]@{Profile=$Profile;Enabled=$Enabled}); foreach ($p in $Profile) {$script:profileOn[$p]=[string]$Enabled}}
function New-NetFirewallRule {
    param($Name,$DisplayName,$Group,$Direction,$Action,$InterfaceType,$Profile,$Protocol,$RemoteAddress,$LocalPort,$RemotePort,$Program)
    $state=(Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).Status
    $rule=[pscustomobject]@{Name=$Name;Group=$Group;Direction=$Direction;Action=$Action;InterfaceType=$InterfaceType;Profile=$Profile;Protocol=$Protocol;RemoteAddress=@($RemoteAddress);LocalPort=$LocalPort;RemotePort=$RemotePort;Program=$Program;Enabled='True';StateAtCreation=$state}
    $script:rules+=$rule; Record-Test 'NewFirewallRule' $rule
}
function Get-NetFirewallRule($PolicyStore,$Group,$ErrorAction) {$script:rules}
function Set-NetIPInterface($InterfaceIndex,$AddressFamily,$AutomaticMetric,$InterfaceMetric,$IgnoreDefaultRoutes) {Record-Test 'SetInterface' ([pscustomobject]@{InterfaceIndex=$InterfaceIndex;AutomaticMetric=$AutomaticMetric;InterfaceMetric=$InterfaceMetric;IgnoreDefaultRoutes=$IgnoreDefaultRoutes})}
function New-NetRoute($PolicyStore,$InterfaceIndex,$DestinationPrefix,$NextHop,$RouteMetric) {Record-Test 'NewRoute' ([pscustomobject]@{InterfaceIndex=$InterfaceIndex;DestinationPrefix=$DestinationPrefix;NextHop=$NextHop;PolicyStore=$PolicyStore})}
function Remove-NetRoute {param([Parameter(ValueFromPipeline)]$InputObject,[switch]$Confirm) process {Record-Test 'RemoveRoute' $InputObject}}
function Set-DnsClientServerAddress($InterfaceIndex,$ServerAddresses) {Record-Test 'SetDNS' ([pscustomobject]@{InterfaceIndex=$InterfaceIndex;ServerAddresses=$ServerAddresses})}
function Clear-DnsClientCache {Record-Test 'ClearDNS' $null}
function Test-Blocked([string]$Ip,$Ranges) {
    $n=IPv4-Number $Ip
    foreach ($range in $Ranges) {$p=$range.Split('-'); if ($p.Count -eq 2 -and $n -ge (IPv4-Number $p[0]) -and $n -le (IPv4-Number $p[1])) {return $true}}
    $false
}

try {
    # 1. Normal setup with a hotspot inside 192.168 (Android style).
    Reset-World
    Setup *> $null
    $backup=Index-Of 'Backup'; $firstRule=Index-Of 'NewFirewallRule'; $lastRule=LastIndex-Of 'NewFirewallRule'; $profile=Index-Of 'SetProfile'
    Assert ($backup -ge 0 -and $backup -lt $firstRule) 'Firewall export did not happen before the first rule'
    Assert (@($script:rules | Where-Object {$_.StateAtCreation -ne 'Applying'}).Count -eq 0) 'Rules were created before state.json was saved'
    $firstNetworkChange=@('SetInterface','NewRoute','RemoveRoute','SetDNS' | ForEach-Object {Index-Of $_} | Where-Object {$_ -ge 0} | Measure-Object -Minimum).Minimum
    Assert ($firstNetworkChange -gt $lastRule -and $firstNetworkChange -gt $profile) 'Routes, metrics or DNS changed before the firewall guard was in place'
    Assert ($script:rules.Count -eq 6) ('Expected 6 rules (v4, v6, hotspot x2 directions), got '+$script:rules.Count)
    foreach ($r in $script:rules) {
        Assert ($r.Action -eq 'Block' -and $r.InterfaceType -eq 'Wired' -and $r.Profile -eq 'Any' -and $r.Protocol -eq 'Any') ('Rule scope changed: '+$r.Name)
        Assert (-not $r.LocalPort -and -not $r.RemotePort -and -not $r.Program) ('Rule adds a port or program limit: '+$r.Name)
    }
    $v4=@($script:rules | Where-Object {$_.Name -like '*-v4'})
    Assert ($v4.Count -eq 2) 'Missing IPv4 rule in one direction'
    foreach ($ip in '8.8.8.8','1.1.1.1','10.1.2.3','172.16.5.5','100.64.0.1','192.167.255.255','192.169.0.0','224.0.0.251') {Assert (Test-Blocked $ip $v4[0].RemoteAddress) ($ip+' is not blocked on the wired side')}
    foreach ($ip in '192.168.0.1','192.168.255.254','255.255.255.255') {Assert (-not (Test-Blocked $ip $v4[0].RemoteAddress)) ($ip+' should stay allowed on the wired side')}
    $v6=@($script:rules | Where-Object {$_.Name -like '*-v6'})
    Assert ($v6.Count -eq 2 -and $v6[0].RemoteAddress -contains '::/1' -and $v6[0].RemoteAddress -contains '8000::/1') 'IPv6 is not fully blocked'
    $hotspot=@($script:rules | Where-Object {$_.Name -like '*-hotspot'})
    Assert ($hotspot.Count -eq 2 -and $hotspot[0].RemoteAddress -contains '192.168.43.0/24') 'Hotspot subnet inside 192.168 is not blocked on the wired side'
    $ifaces=@($script:ops | Where-Object Name -eq SetInterface)
    Assert ($ifaces | Where-Object {$_.Data.InterfaceIndex -eq 11 -and $_.Data.InterfaceMetric -eq 10}) 'Wi-Fi metric not set to 10'
    Assert ($ifaces | Where-Object {$_.Data.InterfaceIndex -eq 12 -and $_.Data.InterfaceMetric -eq 500 -and $_.Data.IgnoreDefaultRoutes -eq 'Enabled'}) 'Ethernet metric / IgnoreDefaultRoutes not set'
    Assert (@($script:ops | Where-Object {$_.Name -eq 'SetInterface' -and $_.Data.InterfaceIndex -eq 11 -and $_.Data.IgnoreDefaultRoutes}).Count -eq 0) 'Wi-Fi default routes were touched'
    Assert ($script:ops | Where-Object {$_.Name -eq 'NewRoute' -and $_.Data.InterfaceIndex -eq 12 -and $_.Data.DestinationPrefix -eq '192.168.0.0/16' -and $_.Data.NextHop -eq '192.168.1.1'}) '192.168.0.0/16 route via the company gateway missing'
    $removedPrefixes=@($script:ops | Where-Object Name -eq RemoveRoute | ForEach-Object {$_.Data.DestinationPrefix} | Sort-Object -Unique)
    Assert (($removedPrefixes -join ',') -eq '0.0.0.0/0,203.0.113.0/24') ('Unexpected removed routes: '+($removedPrefixes -join ','))
    Assert (@($script:ops | Where-Object {$_.Name -eq 'RemoveRoute' -and $_.Data.InterfaceIndex -ne 12}).Count -eq 0) 'A route outside the Ethernet adapter was removed'
    Assert ($script:ops | Where-Object {$_.Name -eq 'SetDNS' -and $_.Data.InterfaceIndex -eq 12 -and $_.Data.ServerAddresses -contains '192.168.43.1'}) 'Ethernet DNS not switched to the Wi-Fi DNS'
    Assert (@($script:ops | Where-Object {$_.Name -eq 'SetDNS' -and $_.Data.InterfaceIndex -eq 11}).Count -eq 0) 'Wi-Fi DNS was changed'
    $state=Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($state.Status -eq 'Applied' -and $state.Gateway -eq '192.168.1.1' -and $state.HotspotPrefix -eq '192.168.43.0/24') 'Final state not recorded'
    $saved=@($state.RemovedRoutes | Where-Object Prefix -eq '203.0.113.0/24')
    Assert ($saved.Count -eq 1 -and $saved[0].Persistent) 'Persistent route was not recorded as persistent'
    Assert ($state.Ethernet.Guid -eq $ethGuid -and $state.Wifi.Guid -eq $wifiGuid) 'Adapters not recorded by GUID'
    $backupDir=Join-Path $Root $state.Backup
    Assert (Test-Path (Join-Path $backupDir 'firewall.wfw')) 'Firewall export missing from the backup folder'
    $original=Get-Content -LiteralPath (Join-Path $backupDir 'state-at-setup.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($original.Status -eq 'Applying' -and $original.Ethernet.Metric -eq 25) 'Original state copy missing from the backup folder'

    # 2. A hotspot outside 192.168 needs no extra rule.
    Reset-World -HotspotIp '172.20.10.5'
    Setup *> $null
    Assert ($script:rules.Count -eq 4 -and @($script:rules | Where-Object {$_.Name -like '*-hotspot'}).Count -eq 0) 'Unexpected hotspot rule for a hotspot outside 192.168'

    # 3. Any other active adapter (VPN, WSL, Hyper-V) stops setup before anything changes.
    Reset-World -ExtraAdapter
    $err=''; try {Setup *> $null} catch {$err=$_.Exception.Message}
    Assert ($err -like '*vEthernet (WSL)*') 'Extra active adapter did not stop setup'
    Assert ($script:ops.Count -eq 0 -and -not (Test-Path $StateFile)) 'Setup changed something before refusing'

    # 4. Overlapping hotspot and company subnets stop setup.
    Reset-World -HotspotIp '192.168.1.77'
    $err=''; try {Setup *> $null} catch {$err=$_.Exception.Message}
    Assert ($err -like '*重叠*' -and $script:ops.Count -eq 0) 'Overlapping subnets did not stop setup'

    # 5. An existing state.json is never overwritten.
    Reset-World
    Set-Content -LiteralPath $StateFile '{"Status":"Applied"}'
    $err=''; try {Setup *> $null} catch {$err=$_.Exception.Message}
    Assert ($err -like '*state.json*' -and $script:ops.Count -eq 0 -and (Get-Content $StateFile -Raw) -like '*Applied*') 'Existing backup was not protected'
    Write-Output 'PASS Test-Setup: backup before rules, rules before routes, blocked ranges exactly outside 192.168/16 (10/8 and 172.16/12 stay blocked), no port or program limits, hotspot rule, Wi-Fi untouched, refusals before any change.'
} finally {Remove-TestRoot}
