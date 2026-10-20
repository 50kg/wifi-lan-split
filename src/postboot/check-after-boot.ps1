param([switch]$Preflight)
$ErrorActionPreference='Stop'
$Root=Join-Path $env:ProgramData 'WifiLanSplit'
$Audit=Join-Path $Root 'PostBoot'
$ConfigPath=Join-Path $Audit 'config.json'
$cfg=Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$kind=if ($Preflight) {'preflight'} else {'boot'}
$Run=Join-Path $Audit ($kind+'-'+(Get-Date -Format yyyyMMdd-HHmmss))
New-Item -ItemType Directory -Force $Run | Out-Null
$log=Join-Path $Run 'checks.jsonl'
$script:LastSample=$null
$script:SampleCount=0
$script:LastProbe=$null
function Log($type,$detail) {
    [pscustomobject]@{Time=(Get-Date -Format o);Type=$type;Detail=$detail} | ConvertTo-Json -Depth 9 -Compress | Add-Content $log -Encoding UTF8
}
function Resolve-Adapter($Guid) {
    $a=@(Get-NetAdapter | Where-Object {([guid]$_.InterfaceGuid).ToString() -eq ([guid]$Guid).ToString()})
    if ($a.Count -ne 1) {throw '未找到配置时的物理网卡，未按编号猜测。'}
    $a[0]
}
function Read-Sample {
    $script:SampleCount++
    $file=Join-Path $Run ('status-'+$script:SampleCount+'.json')
    $engine=Join-Path $Audit 'Engine/backend.ps1'
    $p=Start-Process -FilePath (Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$engine+'" -Mode Status -ResultFile "'+$file+'"') -WindowStyle Hidden -PassThru
    if (-not $p.WaitForExit(20000)) {Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw '配置读取超时。'}
    if (-not (Test-Path $file)) {throw '未收到配置检查结果。'}
    $r=Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $r.Success) {throw ('读取配置失败：'+$r.Message)}
    $w=Resolve-Adapter $cfg.WifiGuid
    $e=Resolve-Adapter $cfg.EthernetGuid
    $task=Get-ScheduledTask -TaskName WifiLanDefaultRouteGuard -ErrorAction SilentlyContinue
    $info=if ($task) {Get-ScheduledTaskInfo -TaskName $task.TaskName} else {$null}
    $bootTrigger=$task -and @($task.Triggers | Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' -and $_.Enabled}).Count -gt 0
    $expectedExe=Join-Path $Root 'RouteGuard.exe'
    $binding=$task -and $task.Actions[0].Execute -eq $expectedExe -and $task.Actions[0].Arguments.ToLowerInvariant().Contains(([guid]$cfg.EthernetGuid).ToString().ToLowerInvariant())
    $processes=@(Get-Process -Name RouteGuard -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $expectedExe})
    $processSinceBoot=@($processes | Where-Object {$_.StartTime.ToUniversalTime() -ge $boot}).Count -gt 0
    $taskSinceBoot=$info -and $info.LastRunTime.ToUniversalTime() -ge $boot
    $defaults4=@(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object InterfaceAlias,InterfaceIndex,NextHop)
    $defaults6=@(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue | Select-Object InterfaceAlias,InterfaceIndex,NextHop)
    $onlyWifiDefaults=@($defaults4 | Where-Object InterfaceIndex -ne $w.ifIndex).Count -eq 0 -and @($defaults4 | Where-Object InterfaceIndex -eq $w.ifIndex).Count -gt 0 -and @($defaults6 | Where-Object InterfaceIndex -ne $w.ifIndex).Count -eq 0
    $routes=@()
    foreach ($ip in @('1.1.1.1','8.8.8.8','9.9.9.9')) {
        $choice=@(Find-NetRoute -RemoteIPAddress $ip -ErrorAction SilentlyContinue)
        $good=$choice.Count -gt 0 -and @($choice | Where-Object InterfaceIndex -ne $w.ifIndex).Count -eq 0
        $routes+=[pscustomobject]@{Target=$ip;WifiSelected=$good;Choices=@($choice | Select-Object InterfaceAlias,InterfaceIndex,IPAddress,NextHop,DestinationPrefix)}
    }
    $safe=[bool]($r.Status.Healthy -and $r.Status.FirewallCoverage -and $r.Status.WifiConnected -and $r.Status.EthernetConnected -and $r.Status.WiredDefaults -eq 0 -and $bootTrigger -and $binding -and $processSinceBoot -and $taskSinceBoot -and $onlyWifiDefaults -and @($routes | Where-Object {-not $_.WifiSelected}).Count -eq 0)
    $s=[pscustomobject]@{Time=(Get-Date -Format o);Ready=$safe;Status=$r.Status;GuardBootTrigger=[bool]$bootTrigger;GuardBindingCorrect=[bool]$binding;GuardProcessStartedSinceBoot=[bool]$processSinceBoot;GuardTaskStartedSinceBoot=[bool]$taskSinceBoot;GuardLastRunTime=if ($info) {$info.LastRunTime.ToString('o')} else {$null};OnlyWifiDefaultRoutes=[bool]$onlyWifiDefaults;DefaultsIPv4=$defaults4;DefaultsIPv6=$defaults6;PublicRouteChoices=$routes}
    Log 'sample' $s
    $script:LastSample=$s
    $s
}
function Probe-Wifi {
    $w=Resolve-Adapter $cfg.WifiGuid
    $ip=Get-NetIPAddress -InterfaceIndex $w.ifIndex -AddressFamily IPv4 | Where-Object AddressState -eq Preferred | Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $ip) {throw 'Wi-Fi 尚无可用 IPv4 地址。'}
    $curl=Join-Path $env:WINDIR 'System32/curl.exe'
    $info=Join-Path $Run 'https-info.txt'; $err=Join-Path $Run 'https-errors.txt'; $headers=Join-Path $Run 'https-headers.txt'
    $arguments='--noproxy "*" --interface '+$ip+' -4 --connect-timeout 5 --max-time 12 -I -sS https://1.1.1.1/ -o "'+$headers+'" -w "local_ip=%{local_ip};remote_ip=%{remote_ip};http_code=%{http_code}"'
    $p=Start-Process -FilePath $curl -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput $info -RedirectStandardError $err -PassThru
    # Cache the native handle before waiting: Windows PowerShell may otherwise return a null ExitCode.
    $null=$p.Handle
    if (-not $p.WaitForExit(16000)) {Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; throw 'Wi-Fi HTTPS 探测超时。'}
    $line=if (Test-Path $info) {(Get-Content $info -Raw).Trim()} else {''}
    $match=[regex]::Match($line,'local_ip=([^;]*);remote_ip=([^;]*);http_code=(\d+)')
    $ok=$p.ExitCode -eq 0 -and $match.Success -and $match.Groups[1].Value -eq $ip -and $match.Groups[2].Value -eq '1.1.1.1' -and [int]$match.Groups[3].Value -ge 200 -and [int]$match.Groups[3].Value -lt 400
    $result=[pscustomobject]@{Success=$ok;ExitCode=$p.ExitCode;ExpectedLocalIP=$ip;Observed=$line;Target='https://1.1.1.1/';ProxyBypassed=$true}
    $script:LastProbe=$result
    Log 'wifi-https' $result
    $result
}
function Finish($outcome,$message,$probe=$null) {
    if (-not $probe) {$probe=$script:LastProbe}
    $report=[pscustomobject]@{Outcome=$outcome;Message=$message;Preflight=[bool]$Preflight;Time=(Get-Date -Format o);BootTimeUtc=$boot.ToString('o');ArmedAt=$cfg.ArmedAt;Samples=$script:SampleCount;LastSample=$script:LastSample;Https=$probe;ReportFolder=$Run;NetworkSettingsChanged=$false;PacketCapturePerformed=$false}
    $report | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $Run 'report.json') -Encoding UTF8
    $s=$script:LastSample
    $lines=@('重启后网络自动检查',('结果：'+$outcome),$message,('生成时间：'+$report.Time),('本次系统启动（UTC）：'+$report.BootTimeUtc),'')
    if ($s) {
        $lines+=@(('路由看守运行：'+$s.Status.GuardRunning),('包含开机启动触发器：'+$s.GuardBootTrigger),('看守绑定原有线网卡：'+$s.GuardBindingCorrect),('看守进程在本次开机后启动：'+$s.GuardProcessStartedSinceBoot),('看守任务在本次开机后运行：'+$s.GuardTaskStartedSinceBoot),('有线默认路由条数：'+$s.Status.WiredDefaults),('防火墙及出站覆盖：'+$s.Status.FirewallCoverage),('Wi-Fi 已连接：'+$s.Status.WifiConnected),('有线已连接：'+$s.Status.EthernetConnected),('所有已发现的默认路由指向 Wi-Fi：'+$s.OnlyWifiDefaultRoutes))
    }
    if ($probe) {$lines+=@(('HTTPS 探测成功：'+$probe.Success),('实际源地址记录：'+$probe.Observed))}
    $lines+=@('','这是开机后的配置与代表性连接检查，不是全量抓包或开机全过程零泄漏证明。','检查不会启动或修复路由看守，不会修改防火墙、路由、DNS、Wi-Fi 或网卡设置。','DHCP 瞬时新增的默认路由仍由现有看守清理，处理窗口继续依靠防火墙阻断。','内网代理、其他隧道和虚拟网络的中转边界仍然存在。',('详细证据：'+$Run))
    $lines | Set-Content (Join-Path $Run 'report.txt') -Encoding UTF8
    $prefix=if ($Preflight) {'preflight'} else {'latest'}
    Copy-Item (Join-Path $Run 'report.json') (Join-Path $Audit ($prefix+'-report.json')) -Force
    Copy-Item (Join-Path $Run 'report.txt') (Join-Path $Audit ($prefix+'-report.txt')) -Force
    if (-not $Preflight) {
        $cfg.Completed=$true
        $cfg | Add-Member CompletedBootTicks $boot.Ticks.ToString() -Force
        $cfg | ConvertTo-Json -Depth 6 | Set-Content $ConfigPath -Encoding UTF8
        Disable-ScheduledTask -TaskName $cfg.TaskName -ErrorAction SilentlyContinue | Out-Null
    }
}
try {
    if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -ne $cfg.MachineGuid) {throw '检查配置属于其他 Windows 安装，已拒绝执行。'}
    if (-not $Preflight -and $cfg.Completed) {exit 0}
    if (-not $Preflight -and $boot.Ticks.ToString() -eq $cfg.ArmedBootTicks) {
        Log 'armed' '尚未检测到新的系统启动；不会把当前预检当作重启后的结果。'
        exit 0
    }
    $state=Get-Content (Join-Path $Root 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.Status -ne 'Applied') {Finish 'CANCELLED' '分流设置已还原或未完成，因此不再进行公网探测。'; exit 0}
    $deadline=(Get-Date).AddSeconds([int]$cfg.WaitSeconds)
    $stable=0; $need=if ($Preflight) {1} else {[int]$cfg.RequiredStableSamples}
    $lastError=''
    do {
        try {
            $s=Read-Sample
            if ($s.Ready) {$stable++} else {$stable=0}
            if ($stable -ge $need) {
                $probe=Probe-Wifi
                if ($probe.Success) {
                    # Re-read after the connection to avoid reporting a stale routing state.
                    $final=Read-Sample
                    if ($final.Ready) {Finish $(if ($Preflight) {'PREFLIGHT_PASS'} else {'PASS'}) $(if ($Preflight) {'当前只读预检通过；仍等待用户手动重启后正式检查。'} else {'本次重启后，看守自动启动的配置及运行证据符合预期；有线默认路由为 0，代表性公网路由和 HTTPS 源地址均为 Wi-Fi。'}) $probe; exit 0}
                }
                $stable=0
            }
        } catch {$lastError=$_.Exception.Message;Log 'error' $lastError;$stable=0}
        if ($Preflight) {break}
        Start-Sleep -Seconds ([int]$cfg.IntervalSeconds)
    } while ((Get-Date) -lt $deadline)
    Finish 'INCOMPLETE' ('未能在等待窗口内完成验证。请查看网卡是否连接、看守和防火墙状态；不会把未完成检查当作通过。'+$lastError)
} catch {Finish 'ERROR' $_.Exception.Message}
