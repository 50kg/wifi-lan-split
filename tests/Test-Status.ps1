$ErrorActionPreference='Stop'
# Runs backend Get-Status against fictional adapters, rules and tasks. Every system command it reads is mocked.
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
. (Join-Path $PSScriptRoot '..\src\powershell\backend.ps1')
$Root=Join-Path $TestRoot 'root'; $Package=Join-Path $TestRoot 'package'; $StateFile=Join-Path $Root 'state.json'
New-Item -ItemType Directory -Force $Root,$Package | Out-Null
Use-TestRoot
$wifiGuid='{11111111-1111-1111-1111-111111111111}'; $ethGuid='{22222222-2222-2222-2222-222222222222}'

function Get-ItemProperty($Path) {[pscustomobject]@{MachineGuid='synthetic'}}
function Get-PathTrustProblem([string]$Path) {if ($script:rootProblem -and $Path -eq $Root) {$script:rootProblem} else {''}}
function Get-NetAdapter([switch]$Physical) {if ($Physical) {$script:adapters | Where-Object Physical} else {$script:adapters}}
function Get-NetIPAddress($InterfaceIndex,$AddressFamily,$ErrorAction) {$script:addresses[[int]$InterfaceIndex]}
function Get-NetRoute($InterfaceIndex,$AddressFamily,$DestinationPrefix,$ErrorAction) {$script:defaults[[int]$InterfaceIndex]}
function Get-NetIPInterface($InterfaceIndex,$AddressFamily,$ErrorAction) {[pscustomobject]@{IgnoreDefaultRoutes='Enabled'}}
function Find-NetRoute($RemoteIPAddress,$ErrorAction) {[pscustomobject]@{InterfaceIndex=$script:publicIndex}}
function Get-NetFirewallRule($PolicyStore,$Group,$ErrorAction) {$script:rules}
function Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline)]$InputObject) process {[pscustomobject]@{Protocol='Any';LocalPort='Any';RemotePort='Any'}}}
function Get-NetFirewallApplicationFilter {param([Parameter(ValueFromPipeline)]$InputObject) process {[pscustomobject]@{Program=$InputObject.Program;Package=''}}}
function Get-NetFirewallSecurityFilter {param([Parameter(ValueFromPipeline)]$InputObject) process {[pscustomobject]@{LocalUser=$InputObject.LocalUser;RemoteUser='Any';RemoteMachine='Any'}}}
function Get-NetFirewallServiceFilter {param([Parameter(ValueFromPipeline)]$InputObject) process {[pscustomobject]@{Service='Any'}}}
function Get-NetFirewallAddressFilter {param([Parameter(ValueFromPipeline)]$InputObject) process {[pscustomobject]@{RemoteAddress=$InputObject.Remote;LocalAddress='Any'}}}
function Get-NetFirewallInterfaceTypeFilter {param([Parameter(ValueFromPipeline)]$InputObject) process {[pscustomobject]@{InterfaceType=$InputObject.IfType}}}
function Get-NetFirewallInterfaceFilter {param([Parameter(ValueFromPipeline)]$InputObject) process {[pscustomobject]@{InterfaceAlias=$InputObject.Alias}}}
function Get-NetFirewallProfile($PolicyStore) {'Domain','Private','Public' | ForEach-Object {[pscustomobject]@{Name=$_;Enabled=$script:firewallOn}}}
function Get-ScheduledTask($TaskName,$ErrorAction) {if ($script:taskState) {[pscustomobject]@{State=$script:taskState}}}

function Ip($a) {[pscustomobject]@{IPAddress=$a;PrefixLength=24;AddressState='Preferred'}}
function Route($hop) {[pscustomobject]@{NextHop=$hop}}
function Rule($remote,[string]$IfType='Any',$Alias=@('以太网'),[string]$Program='Any',[string]$LocalUser='Any') {[pscustomobject]@{Enabled='True';Action='Block';Direction='Outbound';Profile='Any';Alias=$Alias;IfType=$IfType;Remote=$remote;Program=$Program;LocalUser=$LocalUser}}
function Legacy-Rules {@((Rule @('0.0.0.0-192.167.255.255','192.169.0.0-255.255.255.254')),(Rule @('192.168.50.0/255.255.255.0')),(Rule @('::/1','8000::/1')))}
function V2-Rules {@((Rule @('0.0.0.0-192.167.255.255','192.169.0.0-255.255.255.254') 'Wired' @('Any')),(Rule @('::/1','8000::/1') 'Wired' @('Any')),(Rule @('192.168.50.0/24') 'Wired' @('Any')))}
function Set-World {
    param([string]$StateStatus='Applied',[string]$WifiIp='192.168.50.5',[int]$EthDefaults=0,$Rules=(Legacy-Rules),[string]$Task='Running',[switch]$Dock,[switch]$WifiDown,[switch]$EthMissing,[string]$RootProblem='',[switch]$Outdated)
    $script:adapters=@(
        [pscustomobject]@{Name='WLAN';MediaType='Native 802.11';Status=$(if ($WifiDown) {'Disconnected'} else {'Up'});ifIndex=11;InterfaceGuid=$wifiGuid;Physical=$true},
        [pscustomobject]@{Name='Tailscale';MediaType='IP';Status='Up';ifIndex=40;InterfaceGuid='{44444444-4444-4444-4444-444444444444}';Physical=$false}
    )
    if (-not $EthMissing) {$script:adapters+=[pscustomobject]@{Name='以太网';MediaType='802.3';Status='Up';ifIndex=12;InterfaceGuid=$ethGuid;Physical=$true}}
    $script:addresses=@{11=(Ip $WifiIp);12=(Ip '192.168.1.23')}
    $script:defaults=@{11=@(Route 'x');12=@(for ($i=0; $i -lt $EthDefaults; $i++) {Route '192.168.1.1'})}
    if ($Dock) {
        $script:adapters+=[pscustomobject]@{Name='USB 以太网';MediaType='802.3';Status='Up';ifIndex=13;InterfaceGuid='{33333333-3333-3333-3333-333333333333}';Physical=$true}
        $script:addresses[13]=(Ip '192.168.1.77'); $script:defaults[13]=@(Route '192.168.1.1')
    }
    $script:rules=$Rules; $script:taskState=$Task; $script:firewallOn='True'; $script:publicIndex=11; $script:rootProblem=$RootProblem
    if (Test-Path $StateFile) {Remove-Item $StateFile}
    if ($StateStatus) {[pscustomobject]@{Version=2;Status=$StateStatus;MachineGuid='synthetic';Wifi=@{Guid=$wifiGuid};Ethernet=@{Guid=$ethGuid}} | ConvertTo-Json | Set-Content -Encoding UTF8 $StateFile}
    Set-Content (Join-Path $Root 'guard-heartbeat.txt') 'fresh'
    Set-Content (Join-Path $Root 'RouteGuard.exe') 'deployed build'
    Set-Content (Join-Path $Package 'RouteGuard.exe') $(if ($Outdated) {'newer build'} else {'deployed build'})
}
function Check-Of($s,$key) {@($s.Checks | Where-Object Key -eq $key)[0]}

try {
    Set-World
    $s=Get-Status
    Assert ($s.Healthy -and $s.Summary.Level -eq 'ok' -and $s.Summary.Action -eq '') 'A: healthy legacy setup not reported as healthy'
    Assert ((Check-Of $s 'firewall').Detail -like '*仅限“以太网”*') 'A: alias-bound rules are not called out'
    Assert ((Check-Of $s 'other').State -eq 'info' -and (Check-Of $s 'other').Detail -like 'Tailscale*') 'A: Tailscale not listed as outside the tool'
    Assert ($s.EthernetRestricted -and $s.PublicInterface -eq 'WLAN' -and -not $s.GuardOutdated) 'A: adapter roles wrong'
    Assert ((@($s.Adapters | ForEach-Object {$_.Label+'='+$_.Role}) -join ';') -eq 'Wi-Fi=公网出口;网线=只能访问 192.168 内网') 'A: adapter rows not labelled in the user''s words'

    Set-World -WifiIp '192.168.60.5'
    $s=Get-Status
    Assert (-not $s.Healthy -and $s.Summary.Level -eq 'warn' -and $s.Summary.Title -eq '热点子网没有阻断' -and $s.Summary.Action -eq '' -and $s.Summary.Reason -like '*还原*') 'B: moved hotspot not explained'

    Set-World -Dock
    $s=Get-Status
    Assert (-not $s.Healthy -and $s.Summary.Level -eq 'error' -and $s.Summary.Title -like '*USB 以太网*可以直接上公网' -and $s.Summary.Action -eq 'Adapters') 'C: uncovered second wired NIC reported as healthy'
    Assert ($s.Adapters[0].Label -eq '网线 2' -and $s.Adapters[0].Role -eq '未限制' -and $s.Adapters[0].RoleLevel -eq 'error') 'C: uncovered NIC is not listed first among adapters'

    Set-World -Dock -Rules (V2-Rules)
    $s=Get-Status
    Assert (-not $s.Healthy -and $s.Summary.Level -eq 'warn' -and (Check-Of $s 'other-wired').Detail -like '*默认路由*') 'D: covered second NIC with default route not flagged'

    Set-World -Task 'Ready' -EthDefaults 1
    $s=Get-Status
    Assert (-not $s.Healthy -and $s.Summary.Level -eq 'warn' -and $s.Summary.Action -eq 'Repair' -and $s.Summary.Reason -like '*防火墙仍在阻断*') 'E: stopped guard not offered for repair'

    Set-World -StateStatus '' -Rules @() -Task '' -EthDefaults 1
    $s=Get-Status
    Assert ($s.Summary.Level -eq 'error' -and $s.Summary.Title -eq '尚未启用分流' -and $s.Summary.Action -eq 'Setup' -and $s.Summary.Reason -like '*直接访问公网*') 'F: exposed new machine not flagged'

    Set-World -StateStatus '' -Rules @() -Task '' -WifiDown
    $s=Get-Status
    Assert ($s.Summary.Level -eq 'warn' -and $s.Summary.Action -eq '') 'G: setup offered without Wi-Fi'

    Set-World -StateStatus 'Applying'
    $s=Get-Status
    Assert ($s.Summary.Level -eq 'error' -and $s.Summary.Title -like '*上次启用没有完成*' -and $s.Summary.Action -eq '' -and $s.CanRestore) 'H: half-applied setup not flagged'

    Set-World -EthMissing
    $s=Get-Status
    Assert ($s.Summary.Level -eq 'error' -and $s.Summary.Title -like '*找不到原来的网卡*') 'I: missing adapter not flagged'

    Set-World -RootProblem 'S-1-5-32-545 可以写入'
    $s=Get-Status
    Assert ($s.Summary.Level -eq 'error' -and $s.Summary.Title -like '*数据目录权限异常*') 'J: unsafe data folder not flagged'

    Set-World -Outdated
    $s=Get-Status
    Assert ($s.Healthy -and $s.GuardOutdated -and (Check-Of $s 'guard-version').Fix -eq 'Update') 'K: outdated guard not offered as an update'

    Set-World -Rules @((Rule @('0.0.0.0-192.167.255.255','192.169.0.0-255.255.255.254') -Program 'C:\Tools\app.exe'),(Rule @('::/1','8000::/1')))
    $s=Get-Status
    Assert (-not $s.Healthy -and (Check-Of $s 'firewall').State -eq 'error') 'L: a program-limited rule counted as full coverage'

    Set-World -Rules @((Rule @('0.0.0.0-192.167.255.255','192.169.0.0-255.255.255.254') -LocalUser 'D:(A;;CC;;;S-1-5-21-1)'),(Rule @('::/1','8000::/1')))
    $s=Get-Status
    Assert (-not $s.Healthy -and (Check-Of $s 'firewall').State -eq 'error') 'M: a user-limited rule counted as full coverage'

    Set-World -Dock -Rules @((Rule @('0.0.0.0-192.167.255.255','192.169.0.0-255.255.255.254') 'Wired' @('以太网')),(Rule @('::/1','8000::/1') 'Wired' @('以太网')),(Rule @('192.168.50.0/24') 'Wired' @('以太网')))
    $s=Get-Status
    Assert ($s.Summary.Level -eq 'error' -and $s.Summary.Title -like '*USB 以太网*') 'N: a Wired rule limited to one alias was treated as covering every wired adapter'

    Set-World -StateStatus '' -Task 'Running'
    $s=Get-Status
    Assert ($s.Summary.Level -eq 'error' -and $s.Summary.Title -eq '找不到备份状态' -and $s.Summary.Action -eq '') 'O: rules without state.json offered setup'

    Set-World -Outdated -WifiIp '192.168.60.5'
    $s=Get-Status
    Assert ((Check-Of $s 'guard-version').Fix -eq '') 'P: guard update offered while the firewall check fails'

    Set-World
    $held=[IO.File]::Open((Join-Path $Root 'operation.lock'),'OpenOrCreate','ReadWrite','None')
    try {$s=Get-Status} finally {$held.Dispose()}
    Assert ($s.Busy -and $s.Summary.Title -eq '另一项操作正在进行' -and $s.Summary.Action -eq '') 'Q: a running change was not reported'
    $s=Get-Status
    Assert (-not $s.Busy -and $s.Healthy) 'Q: a released lock still reads as busy'

    $json=$s | ConvertTo-Json -Depth 8
    Assert ($json -like '*"Checks"*' -and $json -like '*"Summary"*') 'Status does not serialize checks and summary'
    Write-Output 'PASS Test-Status: healthy, moved hotspot, uncovered/covered second wired NIC, stopped guard, exposed new machine, no Wi-Fi, half-applied, missing adapter, unsafe data folder, outdated guard, program- and user-limited rules, alias-limited Wired rule, rules without state.json, update hidden while firewall incomplete, change in progress.'
} finally {Remove-TestRoot}
