$ErrorActionPreference = 'Stop'
$Group = 'WifiPublicWiredLAN-v2'
$StateFile = Join-Path $Root 'state.json'
$NetshExe = Join-Path $env:SystemRoot 'System32\netsh.exe'
$ResultCode = 0
$SkipPause = $false

function Is-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Adapter-ByGuid($Guid) {
    $a = @(Get-NetAdapter | Where-Object { ([guid]$_.InterfaceGuid).ToString() -eq ([guid]$Guid).ToString() })
    if ($a.Count -ne 1) { throw "找不到启用时的网卡（GUID $Guid）。不会按编号猜测替代网卡。" }
    $a[0]
}
function IPv4-Number([string]$Address) {
    $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    if ($bytes.Length -ne 4) { throw 'IPv4 required' }
    [array]::Reverse($bytes)
    [uint64][BitConverter]::ToUInt32($bytes,0)
}
function Number-IPv4([uint64]$Number) {
    $bytes = [BitConverter]::GetBytes([uint32]$Number)
    [array]::Reverse($bytes)
    ([Net.IPAddress]::new($bytes)).ToString()
}
function IPv4-Network($Ip) {
    $size = [uint64][Math]::Pow(2,32-[int]$Ip.PrefixLength)
    $first = [uint64]([Math]::Floor((IPv4-Number $Ip.IPAddress)/$size)*$size)
    [pscustomobject]@{ First=$first; Last=($first+$size-1); Prefix=((Number-IPv4 $first)+'/'+$Ip.PrefixLength) }
}
function Is-PrivatePrefix([string]$Prefix) {
    $parts=$Prefix.Split('/')
    $parts.Count -eq 2 -and [int]$parts[1] -ge 16 -and $parts[0] -like '192.168.*'
}
function Choose-Adapters {
    $physical = @(Get-NetAdapter -Physical)
    $w = @($physical | Where-Object { $_.MediaType.ToString() -eq 'Native 802.11' -and $_.Status -eq 'Up' })
    $e = @($physical | Where-Object { $_.MediaType.ToString() -eq '802.3' -and $_.Status -eq 'Up' })
    if ($w.Count -ne 1 -or $e.Count -ne 1) {
        $physical | Format-Table Name,MediaType,Status,InterfaceGuid | Out-Host
        throw '需要恰好一张已连接的物理 Wi-Fi 网卡和一张已连接的物理有线网卡。请连接两者、断开其他网卡后重试。'
    }
    @($w[0],$e[0])
}
function Interface-Snapshot($Adapter) {
    $ip=Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    $guid=([guid]$Adapter.InterfaceGuid).ToString('B')
    $reg=Get-ItemProperty ('HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\'+$guid)
    [pscustomobject]@{
        Guid=$guid; Name=$Adapter.Name; Metric=[int]$ip.InterfaceMetric
        AutomaticMetric=$ip.AutomaticMetric.ToString(); IgnoreDefaultRoutes=$ip.IgnoreDefaultRoutes.ToString()
        StaticDns=[bool]$reg.NameServer
        Dns=@((Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
    }
}
function Set-AdminOwner([string]$Path) {
    # Files this tool creates belong to Administrators, also where new objects default to the creating user.
    # Only the owner section is written; the file's permissions are left as they are.
    try {
        if ((Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-32-544') {
            $owner = New-Object Security.AccessControl.FileSecurity
            $owner.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
            [IO.File]::SetAccessControl($Path, $owner)
        }
    } catch {}
}
function Save-State($State) {
    # state.json is the only record of the original settings: write a fresh temp file, then swap it in.
    $json = $State | ConvertTo-Json -Depth 9
    $temp = $StateFile + '.tmp'
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding $true))
    Set-AdminOwner $temp
    if (-not (Test-Path -LiteralPath $StateFile)) { [IO.File]::Move($temp, $StateFile); return }
    try { [IO.File]::Replace($temp, $StateFile, $StateFile + '.previous') }
    catch {
        # A failed replace can leave only the backup and the temp file; never leave the tool without a state.json.
        if (-not (Test-Path -LiteralPath $StateFile)) { [IO.File]::Move($temp, $StateFile) }
        throw
    }
}
function Load-State {
    if (-not (Test-Path $StateFile)) {
        if (Test-Path ($StateFile + '.previous')) { throw '找不到 state.json，但有 state.json.previous。请管理员核对后把它改名为 state.json 再还原。' }
        throw '找不到 state.json。还原需要这台电脑自己的备份文件夹。'
    }
    $s=Get-Content -Encoding UTF8 $StateFile -Raw | ConvertFrom-Json
    $machine=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    if ($machine -ne $s.MachineGuid) { throw '备份属于另一个 Windows 安装，拒绝使用。' }
    $s
}
function Show-Check {
    Get-NetAdapter | Format-Table Name,InterfaceDescription,Status,ifIndex | Out-Host
    Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,IPAddress,PrefixLength,AddressState | Out-Host
    Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','192.168.0.0/16') } | Format-Table DestinationPrefix,NextHop,InterfaceAlias,RouteMetric | Out-Host
    Get-NetFirewallProfile -PolicyStore ActiveStore | Format-Table Name,Enabled,AllowLocalFirewallRules | Out-Host
    Get-NetFirewallRule -PolicyStore ActiveStore -Group @($Group,'CodexStrictSplit20261016') -ErrorAction SilentlyContinue | Format-Table Name,Enabled,Direction,Action | Out-Host
    Find-NetRoute -RemoteIPAddress 1.1.1.1 | Format-List InterfaceAlias,IPAddress,NextHop | Out-Host
    Find-NetRoute -RemoteIPAddress 192.168.0.1 | Format-List InterfaceAlias,IPAddress,NextHop | Out-Host
    Write-Host 'Read-only check. No Wi-Fi disconnect or network probe performed.'
    Write-Host 'A route listing is not an end-to-end firewall or packet-capture test.'
}
function Setup {
    if (Test-Path $StateFile) { throw '已存在 state.json。请使用检查或还原；不会覆盖原始备份。' }
    $selected=Choose-Adapters
    $wifi=$selected[0]; $eth=$selected[1]
    $other=@(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.ifIndex -notin @($wifi.ifIndex,$eth.ifIndex) })
    if ($other.Count) {
        $other | Format-Table Name,InterfaceDescription | Out-Host
        throw ('还有其他已连接的网络接口：'+(($other | ForEach-Object Name) -join '、')+'。包括 VPN、Tailscale、Hyper-V/WSL/Docker 虚拟网卡。本工具不会替它们做判断；请自行断开或停用后重试。')
    }
    $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore)
    if (@($profiles | Where-Object { $_.AllowLocalFirewallRules.ToString() -eq 'False' }).Count) { throw '组策略禁止本地防火墙规则，需要管理员检查。' }
    if ((Get-Service BFE).Status -ne 'Running' -or (Get-Service MpsSvc).Status -ne 'Running') { throw 'Windows 防火墙服务必须处于运行状态。' }
    $wips=@(Get-NetIPAddress -InterfaceIndex $wifi.ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' })
    $eips=@(Get-NetIPAddress -InterfaceIndex $eth.ifIndex -AddressFamily IPv4 | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -like '192.168.*' })
    if ($wips.Count -ne 1 -or $eips.Count -ne 1) { throw '每张网卡需要恰好一个可用的 IPv4 地址，且网线地址必须是 192.168.x.x。' }
    if ((Get-NetIPInterface -InterfaceIndex $eth.ifIndex -AddressFamily IPv4).Dhcp.ToString() -ne 'Enabled') { throw '网线需要使用 DHCP 自动获取地址；不会猜测固定地址。' }
    $wn=IPv4-Network $wips[0]; $en=IPv4-Network $eips[0]
    if ($en.First -le $wn.Last -and $wn.First -le $en.Last) { throw '网线子网和热点子网重叠。请先更换热点网段。' }
    $gateway=@(Get-NetRoute -InterfaceIndex $eth.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' | Select-Object -ExpandProperty NextHop -Unique)
    if ($gateway.Count -ne 1 -or $gateway[0] -notlike '192.168.*') { throw '无法确定唯一的 192.168.x.x 公司网关。' }
    $dns=@((Get-DnsClientServerAddress -InterfaceIndex $wifi.ifIndex -AddressFamily IPv4).ServerAddresses)
    if (-not $dns.Count) { throw 'Wi-Fi 没有 IPv4 DNS 服务器。' }
    if (-not (Get-NetRoute -InterfaceIndex $wifi.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) { throw 'Wi-Fi 没有 IPv4 默认路由。' }
    if (Get-NetRoute -PolicyStore PersistentStore -InterfaceIndex $eth.ifIndex -DestinationPrefix '192.168.0.0/16' -ErrorAction SilentlyContinue) { throw '网线上已有持久的 192.168.0.0/16 路由，需要人工确认后再使用本工具。' }
    $badRoutes=@(Get-NetRoute -InterfaceIndex $eth.ifIndex -AddressFamily IPv4 | Where-Object { $_.NextHop -ne '0.0.0.0' -and -not (Is-PrivatePrefix $_.DestinationPrefix) })
    $persist=@(Get-NetRoute -PolicyStore PersistentStore -InterfaceIndex $eth.ifIndex -ErrorAction SilentlyContinue)
    $savedRoutes=@(foreach ($r in $badRoutes) {
        [pscustomobject]@{ Prefix=$r.DestinationPrefix; NextHop=$r.NextHop; Metric=[int]$r.RouteMetric; Persistent=[bool]@($persist | Where-Object { $_.DestinationPrefix -eq $r.DestinationPrefix -and $_.NextHop -eq $r.NextHop }).Count }
    })
    $backupName='backup-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
    $backupDir=New-Item -ItemType Directory (Join-Path $Root $backupName)
    & $NetshExe advfirewall export (Join-Path $backupDir.FullName 'firewall.wfw') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw '防火墙备份失败；没有修改任何设置。' }
    $state=[pscustomobject]@{
        Version=2; Status='Applying'; MachineGuid=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
        Backup=$backupName; Wifi=(Interface-Snapshot $wifi); Ethernet=(Interface-Snapshot $eth)
        Gateway=$gateway[0]; HotspotPrefix=$wn.Prefix; RemovedRoutes=$savedRoutes
        Profiles=@(Get-NetFirewallProfile -PolicyStore PersistentStore | Select-Object Name,@{n='Enabled';e={$_.Enabled.ToString()}})
        RouteAdded=$true
    }
    Save-State $state
    # Keep an untouched copy of the original record next to the firewall export.
    Copy-Item -LiteralPath $StateFile -Destination (Join-Path $backupDir.FullName 'state-at-setup.json')
    Set-AdminOwner (Join-Path $backupDir.FullName 'state-at-setup.json')
    Write-Host 'BACKUP READY. Restore.cmd is available offline.' -ForegroundColor Green
    # Scope guards to all wired interfaces, surviving alias changes and additional wired NICs.
    foreach ($direction in @('Outbound','Inbound')) {
        New-NetFirewallRule -Name "$Group-$direction-v4" -DisplayName "$Group $direction outside LAN" -Group $Group -Direction $direction -Action Block -InterfaceType Wired -Profile Any -Protocol Any -RemoteAddress @('0.0.0.0-192.167.255.255','192.169.0.0-255.255.255.254') | Out-Null
        New-NetFirewallRule -Name "$Group-$direction-v6" -DisplayName "$Group $direction IPv6" -Group $Group -Direction $direction -Action Block -InterfaceType Wired -Profile Any -Protocol Any -RemoteAddress @('::/1','8000::/1') | Out-Null
        # Exclude overlapping hotspot destinations from every wired interface.
        if ($wn.First -le (IPv4-Number '192.168.255.255') -and $wn.Last -ge (IPv4-Number '192.168.0.0')) {
            New-NetFirewallRule -Name "$Group-$direction-hotspot" -DisplayName "$Group $direction hotspot" -Group $Group -Direction $direction -Action Block -InterfaceType Wired -Profile Any -Protocol Any -RemoteAddress $wn.Prefix | Out-Null
        }
    }
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
    $effective=@(Get-NetFirewallRule -PolicyStore ActiveStore -Group $Group)
    if (@($effective | Where-Object { $_.Enabled.ToString() -eq 'True' }).Count -lt 4 -or @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { $_.Enabled.ToString() -ne 'True' }).Count) { throw '防火墙阻断规则未能生效。备份已保留；不要认为启用成功。' }
    # Change routes only after the blocking guard is effective.
    Set-NetIPInterface -InterfaceIndex $wifi.ifIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 10
    Set-NetIPInterface -InterfaceIndex $eth.ifIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 500 -IgnoreDefaultRoutes Enabled
    New-NetRoute -InterfaceIndex $eth.ifIndex -DestinationPrefix '192.168.0.0/16' -NextHop $gateway[0] -RouteMetric 10 | Out-Null
    foreach ($r in $savedRoutes) {
        foreach ($store in @('PersistentStore','ActiveStore')) {
            Get-NetRoute -PolicyStore $store -InterfaceIndex $eth.ifIndex -DestinationPrefix $r.Prefix -ErrorAction SilentlyContinue | Where-Object NextHop -eq $r.NextHop | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    # Copy current Wi-Fi DNS; hotspot changes require restore and re-setup.
    Set-DnsClientServerAddress -InterfaceIndex $eth.ifIndex -ServerAddresses $dns
    Clear-DnsClientCache
    $state.Status='Applied'; Save-State $state
    Show-Check
    Write-Host 'Applied. Full disconnect, reboot and packet-capture acceptance tests are still required.' -ForegroundColor Green
}
function Restore {
    $s=Load-State
    if ($s.Status -eq 'Restored') { Write-Host '已经还原过。'; return }
    # Resolve both original identities before making any changes.
    $wifi=Adapter-ByGuid $s.Wifi.Guid; $eth=Adapter-ByGuid $s.Ethernet.Guid
    if ($s.RouteAdded) {
        foreach ($store in @('PersistentStore','ActiveStore')) {
            Get-NetRoute -PolicyStore $store -InterfaceIndex $eth.ifIndex -DestinationPrefix '192.168.0.0/16' -ErrorAction SilentlyContinue | Where-Object NextHop -eq $s.Gateway | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    foreach ($item in @($s.Wifi,$s.Ethernet)) {
        $a=Adapter-ByGuid $item.Guid
        Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric $item.Metric -IgnoreDefaultRoutes $item.IgnoreDefaultRoutes
        if ($item.AutomaticMetric -eq 'Enabled') { Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -AutomaticMetric Enabled }
    }
    foreach ($r in $s.RemovedRoutes) {
        $store=if ($r.Persistent) {'PersistentStore'} else {'ActiveStore'}
        if (-not (Get-NetRoute -PolicyStore $store -InterfaceIndex $eth.ifIndex -DestinationPrefix $r.Prefix -ErrorAction SilentlyContinue | Where-Object NextHop -eq $r.NextHop)) {
            if ($r.Persistent) { New-NetRoute -InterfaceIndex $eth.ifIndex -DestinationPrefix $r.Prefix -NextHop $r.NextHop -RouteMetric $r.Metric | Out-Null }
            else { New-NetRoute -PolicyStore ActiveStore -InterfaceIndex $eth.ifIndex -DestinationPrefix $r.Prefix -NextHop $r.NextHop -RouteMetric $r.Metric | Out-Null }
        }
    }
    if ($s.Ethernet.StaticDns) { Set-DnsClientServerAddress -InterfaceIndex $eth.ifIndex -ServerAddresses @($s.Ethernet.Dns) }
    else { Set-DnsClientServerAddress -InterfaceIndex $eth.ifIndex -ResetServerAddresses }
    Clear-DnsClientCache
    # Remove only this package's rules; preserve unrelated later firewall edits.
    foreach ($ruleGroup in @($Group)+@($s.AdditionalRuleGroups)) { if ($ruleGroup) { Get-NetFirewallRule -Group $ruleGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule } }
    foreach ($p in $s.Profiles) { Set-NetFirewallProfile -Profile $p.Name -Enabled $p.Enabled }
    $s.Status='Restored'; Save-State $s
    Write-Host '已还原原始设置。网线现在可能可以访问公网。' -ForegroundColor Yellow
    Write-Host '备份仍然保留。若要重新启用，请在界面中再次启用，会生成新的备份。'
}
