param([ValidateSet('Status','Setup','Restore','Renew','Repair')][string]$Mode='Status',[string]$ResultFile,[switch]$Console)
$ErrorActionPreference='Stop'
$Root=Join-Path $env:ProgramData 'WifiLanSplit'
$Package=$PSScriptRoot
$TaskName='WifiLanDefaultRouteGuard'
$IpconfigExe=Join-Path $env:SystemRoot 'System32\ipconfig.exe'
. (Join-Path $PSScriptRoot 'network-core.ps1')

# SYSTEM, Administrators, TrustedInstaller may own or write; CREATOR OWNER only as an inheritable ACE.
$TrustedOwnerSids=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$TrustedAceSids=$TrustedOwnerSids+@('S-1-3-0')
# WriteData, AppendData, WriteEA, DeleteChild, WriteAttributes, Delete, WRITE_DAC, WRITE_OWNER, GENERIC_ALL, GENERIC_WRITE
$WriteRightsMask=[int64]0x500D0156
$script:OperationLock=$null

function Get-PathTrustProblem([string]$Path) {
    $acl=Get-Acl -LiteralPath $Path
    $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($TrustedOwnerSids -notcontains $owner) {return ('所有者为 '+$owner)}
    foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType.ToString() -ne 'Allow' -or $TrustedAceSids -contains $rule.IdentityReference.Value) {continue}
        if (([int64]$rule.FileSystemRights -band $WriteRightsMask) -ne 0) {return ($rule.IdentityReference.Value+' 可以写入')}
    }
    ''
}
function New-ProtectedDirectorySecurity {
    $security=New-Object Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity=New-Object Security.Principal.SecurityIdentifier $sid
        $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $security.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $security
}
function Initialize-Root {
    # Create the data folder already locked down, so nothing can be planted in it first.
    if (-not (Test-Path -LiteralPath $Root)) {[void][IO.Directory]::CreateDirectory($Root,(New-ProtectedDirectorySecurity)); return}
    $problem=Get-PathTrustProblem $Root
    if (-not $problem) {return}
    $owner=(Get-Acl -LiteralPath $Root).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($TrustedOwnerSids -notcontains $owner) {throw ('数据目录 '+$Root+' 的权限异常（'+$problem+'），可能被其他程序预先创建。为安全起见已停止，请管理员检查后删除该目录。')}
    [IO.Directory]::SetAccessControl($Root,(New-ProtectedDirectorySecurity))
    # Anything put inside while the folder was open keeps its own owner and explicit rights.
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
        $inner=Get-PathTrustProblem $item.FullName
        if ($inner) {throw ('数据目录里的 '+$item.FullName+' 权限异常（'+$inner+'）。为安全起见已停止，请管理员检查。')}
    }
}
function Assert-TrustedFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {return}
    $problem=Get-PathTrustProblem $Path
    if (-not $problem) {return}
    # Where new files default to the creating admin user, hand the file back to Administrators; any other owner or writer is refused.
    $me=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ((Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value -eq $me) {
        Set-AdminOwner $Path
        $problem=Get-PathTrustProblem $Path
        if (-not $problem) {return}
    }
    throw ('文件 '+$Path+' 的权限异常（'+$problem+'），可能被其他程序改过。为安全起见已停止。')
}
# One change at a time: Setup, Restore, Repair and Renew hold this lock until the process ends.
function Enter-OperationLock {
    try {$script:OperationLock=[IO.File]::Open((Join-Path $Root 'operation.lock'),'OpenOrCreate','ReadWrite','None')}
    catch [IO.IOException] {throw '另一项操作正在进行，请等它完成后再试。'}
}
function Test-OperationBusy {
    if ($script:OperationLock) {return $false}
    $path=Join-Path $Root 'operation.lock'
    if (-not (Test-Path -LiteralPath $path)) {return $false}
    try {$probe=[IO.File]::Open($path,'Open','Read','None'); $probe.Dispose(); $false} catch [IO.IOException] {$true} catch {$false}
}
function Stop-GuardProcess {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $owned=Join-Path $Root 'RouteGuard.exe'
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='RouteGuard.exe'" | Where-Object ExecutablePath -eq $owned)) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $p.ProcessId -Timeout 8 -ErrorAction SilentlyContinue
    }
}
function Stop-Guard {
    Stop-GuardProcess
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false}
}
function Remove-FileWithRetry([string]$Path) {
    for ($i=0; (Test-Path -LiteralPath $Path); $i++) {
        try {Remove-Item -LiteralPath $Path -Force; return} catch {if ($i -ge 10) {throw}; Start-Sleep -Milliseconds 300}
    }
}
function Test-HeartbeatSince([datetime]$Since) {
    $file=Join-Path $Root 'guard-heartbeat.txt'
    (Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).LastWriteTime -gt $Since
}
function Install-Guard($Ethernet) {
    $s=Load-State
    $s | Add-Member GuardTaskName $TaskName -Force
    Save-State $s
    $target=Join-Path $Root 'RouteGuard.exe'
    $source=Join-Path $Package 'RouteGuard.exe'
    if (-not (Test-Path -LiteralPath $source)) {throw '程序包里缺少 RouteGuard.exe。'}
    $hash=(Get-FileHash -LiteralPath $source).Hash
    $replace=(-not (Test-Path -LiteralPath $target)) -or ((Get-FileHash -LiteralPath $target).Hash -ne $hash) -or [bool](Get-PathTrustProblem $target)
    $restartFrom=$null
    if ($replace) {
        # Prepare and verify the new copy while the old guard keeps running.
        $staged=$target+'.new'; $old=$target+'.old'
        Remove-FileWithRetry $staged; Remove-FileWithRetry $old
        Copy-Item -LiteralPath $source -Destination $staged
        Set-AdminOwner $staged
        if ((Get-FileHash -LiteralPath $staged).Hash -ne $hash) {Remove-FileWithRetry $staged; throw '复制的路由看守程序校验失败，原来的看守保持运行。'}
        # Swap it in with the task still registered; if the swap fails, put the old program back and start it again.
        $restartFrom=Get-Date
        Stop-GuardProcess
        try {
            if (Test-Path -LiteralPath $target) {Move-Item -LiteralPath $target -Destination $old}
            Move-Item -LiteralPath $staged -Destination $target
        } catch {
            $reason=$_.Exception.Message
            if (-not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $old)) {Move-Item -LiteralPath $old -Destination $target}
            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {Start-ScheduledTask -TaskName $TaskName}
            throw ('替换路由看守程序失败，已放回原来的程序：'+$reason)
        }
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
    }
    $task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $guid=([guid]$Ethernet.InterfaceGuid).ToString()
    if ($task -and ($task.Actions[0].Execute -ne $target -or -not ([string]$task.Actions[0].Arguments).ToLowerInvariant().Contains($guid))) {
        # The only case that unregisters: a task that runs something else or watches another adapter.
        Stop-GuardProcess
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        $task=$null
        if (-not $restartFrom) {$restartFrom=Get-Date}
    }
    if (-not $task) {
        $action=New-ScheduledTaskAction -Execute $target -Argument ('--watch '+$Ethernet.InterfaceGuid.ToString()+' "'+$Root+'"') -WorkingDirectory $Root
        $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal $principal -Settings $settings -Description 'Remove default IPv4 routes from the configured Ethernet adapter; firewall remains required.' | Out-Null
    }
    Set-NetIPInterface -InterfaceIndex $Ethernet.ifIndex -AddressFamily IPv4 -IgnoreDefaultRoutes Enabled
    if (-not $restartFrom -and ((Get-ScheduledTask -TaskName $TaskName).State.ToString() -ne 'Running' -or -not (Test-HeartbeatSince (Get-Date).AddSeconds(-3)))) {
        # Not running, or running with a stale heartbeat: a stuck process may still hold guard.lock, so end it first.
        $restartFrom=Get-Date
        Stop-GuardProcess
    }
    if ($restartFrom) {Start-ScheduledTask -TaskName $TaskName}
    # Only a heartbeat written after this point counts; an old one from the stopped guard does not.
    $since=if ($restartFrom) {$restartFrom} else {(Get-Date).AddSeconds(-3)}
    $deadline=(Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 300
        $ready=Test-HeartbeatSince $since
        $count=@(Get-NetRoute -InterfaceIndex $Ethernet.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count
    } while ((-not $ready -or $count -ne 0) -and (Get-Date) -lt $deadline)
    if (-not $ready -or $count -ne 0) {throw '路由看守没有通过启动检查。防火墙保护仍然保留，请查看日志。'}
}
function New-Check($Key,$Name,$State,$Detail,$Short='',$Fix='',$Hint='') {
    # State: ok | warn | error | info | off. Fix names the backend mode that can resolve it.
    [pscustomobject]@{Key=$Key;Name=$Name;State=$State;Detail=$Detail;Short=$Short;Fix=$Fix;Hint=$Hint}
}
function Get-FirewallCoverage($Rules,[string]$AdapterName,[string]$HotspotPrefix) {
    $result=[pscustomobject]@{V4=$false;V6=$false;Hotspot=$false;ByType=$false}
    foreach ($r in $Rules) {
        # A rule reaches an adapter when its type is Wired or Any and its alias list is Any or names that adapter.
        $allAliases=$r.Aliases -contains 'Any'
        $applies=($r.Type -eq 'Wired' -or $r.Type -eq 'Any') -and ($allAliases -or ($AdapterName -and $r.Aliases -contains $AdapterName))
        if (-not $applies) {continue}
        if ($r.Addresses -contains '0.0.0.0-192.167.255.255' -and $r.Addresses -contains '192.169.0.0-255.255.255.254') {$result.V4=$true; if ($allAliases) {$result.ByType=$true}}
        if ($r.Addresses -contains '::/1' -and $r.Addresses -contains '8000::/1') {$result.V6=$true}
        if ($HotspotPrefix) {
            foreach ($address in $r.Addresses) {
                $parts=$address.Split('/')
                if ($parts.Count -eq 2) {
                    $bits=if ($parts[1].Contains('.')) {([Convert]::ToString([long](IPv4-Number $parts[1]),2).ToCharArray() | Where-Object {$_ -eq '1'} | Measure-Object).Count} else {[int]$parts[1]}
                    if (($parts[0]+'/'+$bits) -eq $HotspotPrefix) {$result.Hotspot=$true}
                }
            }
        }
    }
    $result
}
function Get-Status {
    $checks=New-Object System.Collections.Generic.List[object]
    $adapters=@(Get-NetAdapter -Physical)
    $ws=@($adapters | Where-Object {$_.MediaType.ToString() -eq 'Native 802.11'})
    $es=@($adapters | Where-Object {$_.MediaType.ToString() -eq '802.3'})
    $w=if ($ws.Count -eq 1) {$ws[0]} else {$null}
    $e=if ($es.Count -eq 1) {$es[0]} else {$null}
    $saved=$null; $stateProblem=''; $missing=@()
    if (Test-Path $StateFile) {
        try {$saved=Load-State} catch {$stateProblem=$_.Exception.Message}
        if ($saved) {
            # A saved configuration names its adapters by GUID; never fall back to a guessed adapter.
            try {$w=Adapter-ByGuid $saved.Wifi.Guid} catch {$w=$null; $missing+='Wi-Fi'}
            try {$e=Adapter-ByGuid $saved.Ethernet.Guid} catch {$e=$null; $missing+='网线'}
        }
    }
    $installed=[bool]($saved -and $saved.Status -eq 'Applied')
    $partial=[bool]($saved -and $saved.Status -eq 'Applying')
    # Rules or the guard task without state.json is not "never set up": offering Setup would back up already-changed settings as the original.
    $leftover=(-not $saved -and -not $stateProblem) -and ((@(Get-NetFirewallRule -PolicyStore ActiveStore -Group @($Group,'CodexStrictSplit20261016') -ErrorAction SilentlyContinue).Count -gt 0) -or [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
    $notSetUp=((-not $saved -and -not $stateProblem) -and -not $leftover) -or [bool]($saved -and $saved.Status -eq 'Restored')
    $wip=if ($w) {@(Get-NetIPAddress -InterfaceIndex $w.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq Preferred | Select-Object -ExpandProperty IPAddress) -join ', '} else {''}
    $eip=if ($e) {@(Get-NetIPAddress -InterfaceIndex $e.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq Preferred | Select-Object -ExpandProperty IPAddress) -join ', '} else {''}
    $wifiUp=[bool]($w -and $w.Status -eq 'Up'); $ethUp=[bool]($e -and $e.Status -eq 'Up')
    $defaults=if ($e) {@(Get-NetRoute -InterfaceIndex $e.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count} else {-1}
    $rules=@(Get-NetFirewallRule -PolicyStore ActiveStore -Group @($Group,'CodexStrictSplit20261016') -ErrorAction SilentlyContinue | Where-Object { $_.Enabled.ToString() -eq 'True' -and $_.Action.ToString() -eq 'Block'})
    # Coverage is read from the actual filters, not from the number of enabled rules.
    $coverRules=@(foreach ($rule in $rules) {
        if ($rule.Direction.ToString() -ne 'Outbound' -or $rule.Profile.ToString() -ne 'Any') {continue}
        $port=$rule | Get-NetFirewallPortFilter
        if ($port.Protocol.ToString() -ne 'Any' -or $port.LocalPort -ne 'Any' -or $port.RemotePort -ne 'Any') {continue}
        $app=$rule | Get-NetFirewallApplicationFilter
        if ($app.Program -ne 'Any' -or -not ([string]::IsNullOrEmpty($app.Package) -or $app.Package -eq 'Any') -or ($rule | Get-NetFirewallServiceFilter).Service -ne 'Any') {continue}
        $security=$rule | Get-NetFirewallSecurityFilter
        if ($security.LocalUser -ne 'Any' -or $security.RemoteUser -ne 'Any' -or $security.RemoteMachine -ne 'Any') {continue}
        $address=$rule | Get-NetFirewallAddressFilter
        if (@($address.LocalAddress) -notcontains 'Any') {continue}
        [pscustomobject]@{Type=($rule | Get-NetFirewallInterfaceTypeFilter).InterfaceType.ToString();Aliases=@(($rule | Get-NetFirewallInterfaceFilter).InterfaceAlias);Addresses=@($address.RemoteAddress)}
    })
    $needsHotspot=$false; $hotspotPrefix=''
    if ($w) {
        $wifiAddress=Get-NetIPAddress -InterfaceIndex $w.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq Preferred | Select-Object -First 1
        if ($wifiAddress) {
            $subnet=IPv4-Network $wifiAddress
            $hotspotPrefix=$subnet.Prefix
            $needsHotspot=$subnet.First -le (IPv4-Number '192.168.255.255') -and $subnet.Last -ge (IPv4-Number '192.168.0.0')
        }
    }
    $ethName=if ($e) {$e.Name} else {''}
    $cov=Get-FirewallCoverage $coverRules $ethName $(if ($needsHotspot) {$hotspotPrefix} else {''})
    $coverage=$cov.V4 -and $cov.V6 -and (-not $needsHotspot -or $cov.Hotspot)
    $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore)
    $firewall=@($profiles | Where-Object {$_.Enabled.ToString() -ne 'True'}).Count -eq 0
    $task=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $heartbeat=if (Test-Path (Join-Path $Root 'guard-heartbeat.txt')) {((Get-Date)-(Get-Item (Join-Path $Root 'guard-heartbeat.txt')).LastWriteTime).TotalSeconds} else {99999}
    $running=[bool]($task -and $task.State -eq 'Running' -and $heartbeat -lt 6)
    $deployedGuard=Join-Path $Root 'RouteGuard.exe'; $packagedGuard=Join-Path $Package 'RouteGuard.exe'
    $guardOutdated=$installed -and (Test-Path -LiteralPath $deployedGuard) -and (Test-Path -LiteralPath $packagedGuard) -and ((Get-FileHash $deployedGuard).Hash -ne (Get-FileHash $packagedGuard).Hash)
    $rootProblem=if (Test-Path -LiteralPath $Root) {Get-PathTrustProblem $Root} else {''}
    $up=@(Get-NetAdapter | Where-Object {$_.Status -eq 'Up'})
    $physicalIndexes=@($adapters | ForEach-Object {$_.ifIndex})
    $others=@($up | Where-Object {(-not $w -or $_.ifIndex -ne $w.ifIndex) -and (-not $e -or $_.ifIndex -ne $e.ifIndex)})
    $publicName=''
    try {
        $choice=@(Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop) | Select-Object -First 1
        if ($choice) {$publicName=@($up | Where-Object {$_.ifIndex -eq $choice.InterfaceIndex} | ForEach-Object {$_.Name}) -join ''}
    } catch {}

    # Detail is the current value shown on the row. Short is the headline when this row is the main problem;
    # Hint answers "can the wired side reach the Internet right now" first, then says what to do.
    $exposedHint='网线可能可以访问公网。'
    if ($stateProblem) {$checks.Add((New-Check 'state' '备份状态' 'error' ('无法读取：'+$stateProblem) '无法读取备份状态' '' '无法确认设置是否完整。请管理员检查数据文件夹里的 state.json。'))}
    if ($leftover) {$checks.Add((New-Check 'state' '备份状态' 'error' '找不到 state.json，但分流规则或看守任务仍在' '找不到备份状态' '' '分流设置可能仍在生效，但没有 state.json 就无法安全还原。请管理员检查数据文件夹里的 state.json.previous。'))}
    if ($partial) {$checks.Add((New-Check 'state' '备份状态' 'error' '上次启用没有完成，设置可能只改了一部分' '上次启用没有完成' 'Restore' '防火墙阻断可能已经生效，但设置不完整。请先还原，再重新启用。'))}
    foreach ($name in $missing) {$checks.Add((New-Check 'adapter' '网卡' 'error' ('找不到启用时的 '+$name+' 网卡，不会按编号猜测替代网卡') '找不到原来的网卡' '' '无法确认网线是否受限。确认网卡没有被禁用或更换，换过网卡就需要还原后重新启用。'))}

    if ($notSetUp -and -not ($cov.V4 -and $cov.V6)) {$checks.Add((New-Check 'firewall' '防火墙阻断' 'off' '未建立'))}
    elseif (-not $firewall) {$checks.Add((New-Check 'firewall' '防火墙阻断' 'error' '有的网络类别关闭了 Windows 防火墙' '有的网络类别关闭了防火墙' '' ($exposedHint+'在 Windows 安全中心为所有网络类别打开防火墙，然后重新检查。')))}
    elseif (-not $cov.V4) {$checks.Add((New-Check 'firewall' '防火墙阻断' 'error' '缺少网线 IPv4 公网阻断规则' '防火墙阻断规则缺失' 'Restore' ($exposedHint+'规则可能被其他软件或管理员删掉了，请先还原，再重新启用。')))}
    elseif (-not $cov.V6) {$checks.Add((New-Check 'firewall' '防火墙阻断' 'error' '缺少网线 IPv6 阻断规则' '防火墙阻断规则缺失' 'Restore' ($exposedHint+'规则可能被其他软件或管理员删掉了，请先还原，再重新启用。')))}
    elseif ($needsHotspot -and -not $cov.Hotspot) {$checks.Add((New-Check 'firewall' '防火墙阻断' 'warn' ('当前热点子网 '+$hotspotPrefix+' 没有阻断') '热点子网没有阻断' 'Restore' '公网仍然被阻断。热点换过网段，请先还原，再连着现在的热点重新启用。'))}
    else {$checks.Add((New-Check 'firewall' '防火墙阻断' 'ok' $(if ($cov.ByType) {'只放行 192.168 内网，IPv6 全部阻断'} else {'只放行 192.168 内网，IPv6 全部阻断 · 仅限“'+$ethName+'”'})))}

    $guardHint='防火墙仍在阻断，网线暂时不会访问公网。'
    if (-not $e) {$checks.Add((New-Check 'routes' '网线默认路由' 'off' '找不到网线网卡'))}
    elseif ($defaults -eq 0) {$checks.Add((New-Check 'routes' '网线默认路由' 'ok' '0 条'))}
    elseif ($notSetUp) {
        if ($cov.V4 -and $cov.V6) {$checks.Add((New-Check 'routes' '网线默认路由' 'warn' ([string]$defaults+' 条，防火墙已阻断')))}
        else {$checks.Add((New-Check 'routes' '网线默认路由' 'error' ([string]$defaults+' 条')))}
    }
    elseif ($running) {$checks.Add((New-Check 'routes' '网线默认路由' 'warn' ([string]$defaults+' 条，看守会自动清除') '网线有默认路由' 'Repair' '防火墙仍在阻断。看守通常在一秒内清除它。'))}
    else {$checks.Add((New-Check 'routes' '网线默认路由' 'warn' ([string]$defaults+' 条') '网线有默认路由' 'Repair' $guardHint))}

    if (-not $installed) {$checks.Add((New-Check 'guard' '路由看守' 'off' '未安装'))}
    elseif (-not $task) {$checks.Add((New-Check 'guard' '路由看守' 'warn' '开机任务不存在' '路由看守没有安装' 'Repair' $guardHint))}
    elseif ($running) {$checks.Add((New-Check 'guard' '路由看守' 'ok' '运行中'))}
    else {$checks.Add((New-Check 'guard' '路由看守' 'warn' '没有运行' '路由看守没有运行' 'Repair' $guardHint))}
    # Updating goes through Repair, which refuses while the firewall is incomplete, so only offer it when it can work.
    if ($guardOutdated) {$checks.Add((New-Check 'guard-version' '看守版本' 'info' '运行中的是旧版本' '' $(if ($coverage -and $firewall) {'Update'} else {''})))}

    # Adapter rows use the user's words (Wi-Fi, 网线, 网线 2); the system name goes next to the address.
    $rows=New-Object System.Collections.Generic.List[object]
    function Add-AdapterRow($Adapter,[string]$Label,[string]$Role,[string]$Level) {
        $ip=if ($Adapter) {@(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object AddressState -eq Preferred | Select-Object -ExpandProperty IPAddress) -join ', '} else {''}
        $connected=[bool]($Adapter -and $Adapter.Status -eq 'Up')
        $rows.Add([pscustomobject]@{Label=$Label;Name=$(if ($Adapter) {$Adapter.Name} else {''});IP=$ip;Connected=$connected;Role=$(if ($connected) {$Role} else {''});RoleLevel=$Level})
    }
    $restricted=$cov.V4 -and $cov.V6
    Add-AdapterRow $w 'Wi-Fi' $(if ($w -and $publicName -eq $w.Name) {'公网出口'} else {''}) 'ok'
    Add-AdapterRow $e '网线' $(if ($restricted) {'只能访问 192.168 内网'} elseif ($e -and $publicName -eq $e.Name) {'公网出口 · 未限制'} else {'未限制'}) $(if ($restricted) {'ok'} else {'error'})
    $outside=@(); $wiredCount=1
    foreach ($a in $others) {
        $wired=$a.MediaType.ToString() -eq '802.3'
        if (-not $wired) {$outside+=$a.Name; continue}
        $otherDefaults=@(Get-NetRoute -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count
        $otherCov=Get-FirewallCoverage $coverRules $a.Name ''
        $physical=$physicalIndexes -contains $a.ifIndex
        $covered=$otherCov.V4 -and $otherCov.V6
        if (-not $physical -and -not $otherDefaults -and -not $covered) {$outside+=$a.Name; continue}
        $wiredCount++
        Add-AdapterRow $a ('网线 '+$wiredCount) $(if ($covered) {'只能访问 192.168 内网'} elseif ($publicName -eq $a.Name) {'公网出口 · 未限制'} else {'未限制'}) $(if ($covered) {'ok'} else {'error'})
        if (-not ($installed -or $partial)) {continue}
        if (-not $covered) {
            $checks.Add((New-Check 'other-wired' ('网线 '+$wiredCount) 'error' $(if ($otherDefaults) {'不在防火墙范围内，有默认路由'} else {'不在防火墙范围内'}) $(if ($otherDefaults) {'“'+$a.Name+'”可以直接上公网'} else {'“'+$a.Name+'”没有防火墙保护'}) 'Adapters' '先在系统里断开它。要长期使用，请还原设置后重新启用。'))
        } elseif ($otherDefaults) {
            $checks.Add((New-Check 'other-wired' ('网线 '+$wiredCount) 'warn' '有默认路由，防火墙已阻断' ('“'+$a.Name+'”有默认路由') 'Adapters' '防火墙已阻断它访问公网，但访问公网可能变慢。断开它，或去掉它的网关。'))
        }
    }
    if ($outside.Count) {$checks.Add((New-Check 'other' '其他接口' 'info' (($outside -join '、')+'：不在本工具控制范围')))}
    if ($rootProblem) {$checks.Add((New-Check 'root' '数据目录' 'error' ('权限异常：'+$rootProblem) '数据目录权限异常' '' ('其他程序可能改过这里的文件。请管理员检查 '+$Root+' 的所有者和权限。')))}

    $problems=@($checks | Where-Object {$_.State -eq 'error' -or $_.State -eq 'warn'})
    if ($notSetUp) {
        $exposed=$ethUp -and $defaults -gt 0 -and -not $restricted
        $ready=$wifiUp -and $ethUp
        $summary=[pscustomobject]@{
            Level=if ($exposed) {'error'} else {'warn'}; Title='尚未启用分流'
            Reason=if ($exposed) {'网线现在可以直接访问公网。'} elseif (-not $ready) {'先连接手机热点 Wi-Fi 和公司网线，再启用分流。'} else {'启用后，公网只走 Wi-Fi，网线只能访问 192.168 内网。'}
            Hint=''; Action=if ($ready) {'Setup'} else {''}
        }
    } elseif ($problems.Count) {
        $first=@($problems | Where-Object State -eq 'error') + @($problems | Where-Object State -eq 'warn') | Select-Object -First 1
        $level=if (@($problems | Where-Object State -eq 'error').Count) {'error'} else {'warn'}
        $action=if (@($problems | Where-Object Fix -ne 'Repair').Count -eq 0) {'Repair'} elseif ($first.Fix -eq 'Adapters') {'Adapters'} else {''}
        $summary=[pscustomobject]@{Level=$level; Title=$first.Short; Reason=$first.Hint; Hint=''; Action=$action}
    } else {
        $summary=[pscustomobject]@{Level='ok'; Title='分流已生效'; Reason='公网走 Wi-Fi，网线只能访问 192.168.0.0/16。'; Hint=''; Action=''}
    }
    # While another change holds the operation lock, the readings may be half-way; say so and offer no actions.
    $busy=Test-OperationBusy
    if ($busy) {$summary=[pscustomobject]@{Level='warn'; Title='另一项操作正在进行'; Reason='完成后再检查一次，结果才准确。'; Hint=''; Action=''}}
    # Problem adapters first, then Wi-Fi and the configured wired adapter.
    $adapterRows=@($rows | Where-Object RoleLevel -eq 'error' | Where-Object Connected) + @($rows | Where-Object {-not ($_.RoleLevel -eq 'error' -and $_.Connected)})
    $ignoreDefaults=''
    if ($e) {try {$ignoreDefaults=(Get-NetIPInterface -InterfaceIndex $e.ifIndex -AddressFamily IPv4 -ErrorAction Stop).IgnoreDefaultRoutes.ToString()} catch {}}
    [pscustomobject]@{
        WifiName=if ($w) {$w.Name} else {'未识别'}; WifiIP=$wip; WifiConnected=$wifiUp
        EthernetName=if ($e) {$e.Name} else {'未识别'}; EthernetIP=$eip; EthernetConnected=$ethUp
        WiredDefaults=$defaults; GuardRunning=$running; FirewallEnabled=[bool]$firewall; BlockRules=$rules.Count
        Installed=$installed; CanRestore=[bool]($saved -and $saved.Status -ne 'Restored')
        Healthy=[bool]($installed -and $problems.Count -eq 0)
        FirewallCoverage=[bool]$coverage; EthernetRestricted=[bool]$restricted
        PublicInterface=$publicName; GuardOutdated=[bool]$guardOutdated
        StateStatus=if ($saved) {[string]$saved.Status} elseif ($stateProblem) {'Unreadable'} else {'None'}
        ExtraAdapters=(@($others | ForEach-Object {$_.Name}) -join '、'); Root=$Root
        IgnoreDefaultRoutes=$ignoreDefaults
        Busy=[bool]$busy; Summary=$summary; Checks=$checks.ToArray(); Adapters=$adapterRows
    }
}
# Tests dot-source this file for its functions only.
if ($MyInvocation.InvocationName -eq '.') {return}
$success=$false; $message=''; $status=$null; $exitCode=0; $transcript=$false
try {
    if (-not (Is-Admin)) {throw '请通过“双网分流.exe”启动，或使用管理员权限运行。'}
    if ($Mode -ne 'Status') {
        Initialize-Root
        Enter-OperationLock
        # The full output goes to a file, so closing the window cannot break a change half way.
        try {Start-Transcript -LiteralPath (Join-Path $Root 'last-operation.log') -Force | Out-Null; $transcript=$true} catch {}
    }
    switch ($Mode) {
        'Status' {$message='状态已刷新。'}
        'Setup' {
            if (Test-Path $StateFile) {
                Assert-TrustedFile $StateFile
                $prior=Load-State
                if ($prior.Status -eq 'Restored') {Move-Item -LiteralPath $StateFile -Destination (Join-Path $Root ('restored-state-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.json'))}
                elseif ($prior.Status -eq 'Applied') {throw '此电脑已经启用分流，请使用检查状态或有线续租验证。'}
                else {throw '存在未完成的配置及备份，请先还原再重新设置。'}
            }
            Setup | Out-Null
            $s=Load-State
            Install-Guard (Adapter-ByGuid $s.Ethernet.Guid)
            $message='已启用分流并启动路由看守。备份已保存，Wi-Fi 没有被断开。'
        }
        'Restore' {
            Assert-TrustedFile $StateFile
            $s=Load-State
            # Resolve identities before stopping any protection.
            $null=Adapter-ByGuid $s.Ethernet.Guid; $null=Adapter-ByGuid $s.Wifi.Guid
            Stop-Guard
            Restore | Out-Null
            $message='已还原这台电脑原来的设置，并卸载路由看守。网线可能重新可以访问公网。'
        }
        'Repair' {
            Assert-TrustedFile $StateFile
            $s=Load-State
            $before=Get-Status
            if (-not $before.FirewallCoverage -or -not $before.FirewallEnabled) {throw '防火墙规则不完整或没有开启，不能只修复看守。请还原后重新启用。'}
            Install-Guard (Adapter-ByGuid $s.Ethernet.Guid)
            $message='路由看守已在运行，网线默认路由为 0。'
        }
        'Renew' {
            Assert-TrustedFile $StateFile
            $s=Load-State; $e=Adapter-ByGuid $s.Ethernet.Guid
            if ((Get-NetIPInterface -InterfaceIndex $e.ifIndex -AddressFamily IPv4).Dhcp.ToString() -ne 'Enabled') {throw '网线现在没有使用 DHCP，不执行续租。'}
            $before=Get-Status
            if (-not $before.Healthy -or -not $before.WifiConnected) {throw '请先确认 Wi-Fi 已连接，并且防火墙和路由看守都正常，再做续租验证。'}
            $log=Join-Path $Root ('dhcp-renew-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.txt')
            & $IpconfigExe /renew $e.Name | Set-Content $log
            if ($LASTEXITCODE -ne 0) {throw ('网线续租命令失败，输出保存在数据文件夹的 '+(Split-Path $log -Leaf)+'。')}
            Start-Sleep -Milliseconds 700
            $after=Get-Status
            $failed=@()
            if ($after.WiredDefaults -ne 0) {$failed+=('网线默认路由还有 '+$after.WiredDefaults+' 条')}
            if (-not $after.GuardRunning) {$failed+='路由看守没有运行'}
            if (-not $after.WifiConnected) {$failed+='Wi-Fi 没有连接'}
            if ($failed.Count) {throw ('续租后检查没有通过：'+($failed -join '，')+'。')}
            $message='网线 DHCP 续租成功：默认路由 0 条，看守正常，Wi-Fi 仍然连接。'
        }
    }
    $status=Get-Status
    if ($Mode -eq 'Status') {$message=if ($status.Healthy) {'检查完成：分流已生效。'} else {'检查完成：'+$status.Summary.Title+'。'}}
    $success=$true
} catch {
    $message=$_.Exception.Message
    $exitCode=1
    try {$status=Get-Status} catch {}
}
$result=[pscustomobject]@{Success=$success; Mode=$Mode; Message=$message; Status=$status; Time=(Get-Date -Format o)}
$json=$result | ConvertTo-Json -Depth 8
if ($transcript) {Write-Host $message; try {Stop-Transcript | Out-Null} catch {}}
if ($ResultFile) {$json | Set-Content -LiteralPath $ResultFile -Encoding UTF8} else {$json}
if ($Console) {Write-Host $message; Read-Host '按回车关闭' | Out-Null}
exit $exitCode
