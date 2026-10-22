# Read-only diagnosis for "The 'Get-Acl' command was found in the module 'Microsoft.PowerShell.Security', but the module
# could not be loaded". Records where Windows PowerShell looks for modules, then runs the backend's first module-dependent
# steps in two child processes: with the module path this window was started with, as v1.0.0 does, and with only Windows
# PowerShell's own modules, as the fixed version does. Each child runs like the backend's status check: a script file with
# $ErrorActionPreference='Stop' (which turns any error during a module import into this failure), the network modules
# loaded first, then Get-Acl; every failure is recorded with its full exception chain. Writes one report to the desktop.
# Changes no setting, needs no administrator rights and reads nothing of the tool's state. Start it from
# 诊断PowerShell模块.cmd, the same way 双网分流.exe is usually started (double-click, or from the same terminal window).
# -ReportFile writes the report there instead, without opening Notepad or waiting for Enter.
param([string]$ReportFile)
$ErrorActionPreference='Stop'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$systemModules=Join-Path $PSHOME 'Modules'
# In the order the backend's status check first uses them; the rest are imported after Get-Acl to show where they come from.
$networkModules=@('NetAdapter','NetSecurity','ScheduledTasks','NetTCPIP','DnsClient')
$laterModules=@('Microsoft.PowerShell.Security','Microsoft.PowerShell.Management','Microsoft.PowerShell.Utility','Microsoft.PowerShell.Host','CimCmdlets')
$modules=$networkModules+$laterModules
# Windows PowerShell rewrites PSModulePath when it starts, so the .cmd passes on the value its window had.
$fromCmd=$env:WLS_DIAG_FROM_CMD -eq '1'
$inherited=if (-not $fromCmd) {$env:PSModulePath} elseif ($env:WLS_DIAG_PSMODULEPATH_UNSET -eq '1') {$null} else {$env:WLS_DIAG_PSMODULEPATH}
foreach ($name in 'WLS_DIAG_FROM_CMD','WLS_DIAG_PSMODULEPATH','WLS_DIAG_PSMODULEPATH_UNSET') {[Environment]::SetEnvironmentVariable($name,$null)}
$report=New-Object System.Collections.Generic.List[string]
function Add-Line([string]$Line) {$report.Add($Line)}
function Read-Safely([scriptblock]$Block) {try {[string](& $Block)} catch {'（无法读取：'+$_.Exception.Message+'）'}}

# The child script. A Security import after a failed Get-Acl is a second try: its result says whether the failure repeats.
$probe=@'
$lines=New-Object System.Collections.Generic.List[string]
$lines.Add('EFFECTIVE '+$env:PSModulePath)
if (__PIN__) {$env:PSModulePath=[IO.Path]::Combine($PSHOME,'Modules')}
$ErrorActionPreference='Stop'
function Get-Chain($Record) {(@(for ($e=$Record.Exception; $e; $e=$e.InnerException) {$e.GetType().Name+': '+($e.Message -replace '\s+',' ').Trim()}) -join ' <= ').Replace('|','/')}
function Import-Probe([string]$Name) {
    try {$m=@(Import-Module $Name -PassThru -ErrorAction Stop)[0]; $lines.Add('MODULE OK|'+$Name+'|'+$m.Version+'|'+$m.Path)}
    catch {$lines.Add('MODULE FAIL|'+$Name+'|'+(Get-Chain $_))}
}
foreach ($name in '__NETWORK__'.Split(',')) {Import-Probe $name}
try {$null=Get-Acl -LiteralPath $env:SystemRoot; $lines.Add('GETACL OK')} catch {$lines.Add('GETACL FAIL|'+(Get-Chain $_))}
try {$null=Get-CimInstance Win32_OperatingSystem; $lines.Add('GETCIM OK')} catch {$lines.Add('GETCIM FAIL|'+(Get-Chain $_))}
foreach ($name in '__LATER__'.Split(',')) {Import-Probe $name}
[IO.File]::WriteAllLines('__OUT__',$lines,(New-Object Text.UTF8Encoding $true))
'@
# A new Windows PowerShell with exactly the inherited module path, as 双网分流.exe starts its backend.
function Invoke-Probe([bool]$Pin) {
    $base=Join-Path ([IO.Path]::GetTempPath()) ('WifiLanSplit-diag-'+[guid]::NewGuid().ToString('N'))
    $script=$base+'.ps1'; $out=$base+'.txt'
    $code=$probe.Replace('__OUT__',$out.Replace("'","''")).Replace('__NETWORK__',($networkModules -join ',')).Replace('__LATER__',($laterModules -join ',')).Replace('__PIN__',$(if ($Pin) {'$true'} else {'$false'}))
    [IO.File]::WriteAllText($script,$code,(New-Object Text.UTF8Encoding $true))
    $si=New-Object Diagnostics.ProcessStartInfo($powershell,('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$script+'"'))
    $si.UseShellExecute=$false; $si.CreateNoWindow=$true
    if ($null -eq $inherited) {$si.EnvironmentVariables.Remove('PSModulePath')} else {$si.EnvironmentVariables['PSModulePath']=$inherited}
    $p=[Diagnostics.Process]::Start($si)
    try {
        if (-not $p.WaitForExit(90000)) {$p.Kill(); return @('TIMEOUT')}
        if (-not (Test-Path -LiteralPath $out)) {return @('NOOUTPUT '+$p.ExitCode)}
        @([IO.File]::ReadAllLines($out))
    } finally {
        $p.Dispose()
        foreach ($f in $script,$out) {if (Test-Path -LiteralPath $f) {Remove-Item -LiteralPath $f -Force}}
    }
}
function Test-Line($Lines,[string]$Line) {@($Lines | Where-Object {$_ -eq $Line}).Count -gt 0}
function Get-Field($Lines,[string]$Prefix) {@($Lines | Where-Object {$_.StartsWith($Prefix)} | ForEach-Object {$_.Substring($Prefix.Length)})}
# The child's steps in the order they ran.
function Add-ProbeResult($Lines) {
    if ($Lines[0] -eq 'TIMEOUT' -or $Lines[0] -like 'NOOUTPUT*') {Add-Line ('  没有完成（'+$Lines[0]+'）'); return}
    foreach ($line in $Lines) {
        $f=$line.Split('|')
        if ($line -like 'MODULE OK|*') {Add-Line ('  导入 '+$f[1]+'：正常  '+$f[2]+'  '+$f[3])}
        elseif ($line -like 'MODULE FAIL|*') {Add-Line ('  导入 '+$f[1]+'：失败  '+$f[2])}
        elseif ($line -like 'GETACL *' -or $line -like 'GETCIM *') {
            $label=if ($line -like 'GETACL*') {'调用 Get-Acl'} else {'调用 Get-CimInstance'}
            Add-Line ('  '+$label+'：'+$(if ($line -like '* OK') {'正常'} else {'失败  '+$f[1]}))
        }
    }
}
# Copies of the modules above in one folder of the search path, with what their manifests declare.
function Get-ModuleCopies([string]$Dir) {
    foreach ($name in $modules) {
        $folder=Join-Path $Dir $name
        if (-not (Test-Path -LiteralPath $folder)) {continue}
        foreach ($psd1 in @(Get-ChildItem -LiteralPath $folder -Filter ($name+'.psd1') -Recurse -Depth 1 -File -ErrorAction SilentlyContinue)) {
            $text=[IO.File]::ReadAllText($psd1.FullName)
            $version=if ($text -match "ModuleVersion\s*=\s*['""]([^'""]+)") {$Matches[1]} else {'?'}
            $edition=if ($text -match 'CompatiblePSEditions\s*=\s*@?\(?\s*([^)\r\n]+)') {$Matches[1] -replace "['""\s]",''} else {'未声明'}
            $foreign=($Dir.TrimEnd('\') -ne $systemModules) -and ($name -like 'Microsoft.PowerShell.*' -or $name -eq 'CimCmdlets')
            '       '+$name+'  版本 '+$version+'  适用 '+$edition+$(if ($foreign) {'  ← 不是 Windows PowerShell 自带的副本，排在自带的前面时会挡住它'} else {''})
        }
    }
}

Write-Host '正在检查 Windows PowerShell 的模块，大约需要半分钟。这个检查只读，不修改任何设置。'
$original=@(Invoke-Probe $false)
$fixed=@(Invoke-Probe $true)
$originalOk=Test-Line $original 'GETACL OK'
$fixedOk=Test-Line $fixed 'GETACL OK'
# After a failed Get-Acl the Security import is the second try; it matters where the fixed version still fails.
$retryOk=Test-Line $fixed 'MODULE OK|Microsoft.PowerShell.Security'

Add-Line '双网分流 · PowerShell 模块诊断（第 2 版：按后台的方式运行）'
Add-Line ('时间：'+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Add-Line '这个检查只读：没有修改网络、防火墙或系统设置，也没有读取双网分流的状态和备份。报告里的路径可能带有 Windows 用户名，发送前可以先看一遍。'
Add-Line ''
Add-Line '[结论]'
if (-not $originalOk -and $fixedOk) {Add-Line '复现了问题：按这个窗口的模块路径，Get-Acl 加载失败；只用 Windows PowerShell 自带模块时正常。修复版就是这样做的，应该能解决。'}
elseif ($originalOk -and $fixedOk) {Add-Line '这次没有复现：按后台的方式（出错即停、先加载网络模块）运行，两种模块路径下 Get-Acl 都正常。如果双网分流现在仍然报错，请把界面日志里那一行完整发给开发者，新版会在报错后面写出原因；如果旧版也不再报错，之前很可能是暂时性问题。'}
elseif ($retryOk) {Add-Line 'Get-Acl 加载失败，但紧接着再次导入 Security 模块成功，可能是暂时性问题（例如安全软件或系统更新正在进行）。请把这份报告完整发给开发者。'}
else {Add-Line '只用 Windows PowerShell 自带模块时 Get-Acl 仍然失败，原因不只是模块路径。下面“测试”部分的失败原因是关键，请把这份报告完整发给开发者。'}
$failures=@($original | Where-Object {$_ -like 'MODULE FAIL|*'} | ForEach-Object {$_.Split('|')[1]})
if ($failures.Count) {Add-Line ('按这个窗口的模块路径无法导入：'+($failures -join '、'))}
Add-Line ''
Add-Line '[环境]'
Add-Line ('Windows：'+(Read-Safely {$v=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; $v.ProductName+' '+$v.DisplayVersion+'（版本 '+$v.CurrentBuild+'.'+$v.UBR+'）'}))
Add-Line ('界面语言：'+(Read-Safely {(Get-UICulture).Name}))
Add-Line ('Windows PowerShell：'+$PSVersionTable.PSVersion+'，64 位进程：'+[Environment]::Is64BitProcess+'，64 位系统：'+[Environment]::Is64BitOperatingSystem)
Add-Line ('以管理员身份运行：'+(Read-Safely {([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}))
Add-Line ('启动方式：'+(Read-Safely {
    $chain=@(); $id=$PID
    for ($i=0; $i -lt 6 -and $id; $i++) {
        $p=@(([wmisearcher]('SELECT Name,ParentProcessId FROM Win32_Process WHERE ProcessId='+$id)).Get())
        if (-not $p.Count) {break}
        $chain+=$p[0].Name; $id=$p[0].ParentProcessId
    }
    $chain -join ' ← '
}))
Add-Line ('通过 诊断PowerShell模块.cmd 启动：'+$(if ($fromCmd) {'是'} else {'否（下面“窗口继承的值”可能已被 PowerShell 改写）'}))
Add-Line ('上次开机：'+(Read-Safely {$os=@(([wmisearcher]'SELECT LastBootUpTime FROM Win32_OperatingSystem').Get())[0]; [Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime).ToString('yyyy-MM-dd HH:mm')}))
Add-Line ('系统更新等待重启：'+(Read-Safely {
    $keys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending','HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if (@($keys | Where-Object {Test-Path -LiteralPath $_}).Count) {'是'} else {'否'}
}))
Add-Line ('安全软件：'+(Read-Safely {
    $names=@((New-Object Management.ManagementObjectSearcher('root\SecurityCenter2','SELECT displayName FROM AntiVirusProduct')).Get() | ForEach-Object {$_['displayName']})
    if ($names.Count) {$names -join '、'} else {'没有登记'}
}))
Add-Line ('PowerShell 7：'+(Read-Safely {
    $found=@(Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'PowerShell') -Directory -ErrorAction SilentlyContinue | Where-Object {Test-Path -LiteralPath (Join-Path $_.FullName 'pwsh.exe')} | ForEach-Object {$_.FullName})
    $onPath=@(Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object {$_.Source})
    if ($found.Count -or $onPath.Count) {(@($found)+@($onPath | ForEach-Object {'PATH 中：'+$_}) | Select-Object -Unique) -join '；'} else {'没有找到'}
}))
Add-Line ''
Add-Line '[模块搜索路径]'
Add-Line ('窗口继承的值：'+$(if ($null -eq $inherited) {'（未设置）'} else {$inherited}))
Add-Line ('系统级设置：'+(Read-Safely {$v=[Environment]::GetEnvironmentVariable('PSModulePath','Machine'); if ($null -eq $v) {'（未设置）'} else {$v}}))
Add-Line ('用户级设置：'+(Read-Safely {$v=[Environment]::GetEnvironmentVariable('PSModulePath','User'); if ($null -eq $v) {'（未设置）'} else {$v}}))
Add-Line '后台实际的查找顺序（v1.0.0，按窗口继承的值），以及每个位置里和后台有关的模块：'
$effective=@(Get-Field $original 'EFFECTIVE ')
if ($effective.Count) {
    $n=0
    foreach ($entry in @($effective[0].Split(';') | Where-Object {$_.Trim()})) {
        $n++
        $dir=[Environment]::ExpandEnvironmentVariables($entry.Trim())
        try {
            $exists=Test-Path -LiteralPath $dir
            Add-Line ('  '+$n+'. '+$dir+$(if (-not $exists) {'  （不存在）'} else {''}))
            if ($exists) {foreach ($line in @(Get-ModuleCopies $dir)) {Add-Line $line}}
        } catch {Add-Line ('  '+$n+'. '+$dir+'  （无法读取：'+$_.Exception.Message+'）')}
    }
} else {Add-Line '  （没有取到）'}
Add-Line ''
Add-Line '[测试一：按窗口继承的模块路径（和 v1.0.0 一样），出错即停，按执行顺序]'
Add-ProbeResult $original
Add-Line ''
Add-Line '[测试二：只用 Windows PowerShell 自带模块（修复版的做法），出错即停，按执行顺序]'
Add-ProbeResult $fixed

if ($ReportFile) {[IO.File]::WriteAllLines([IO.Path]::GetFullPath($ReportFile),$report,(New-Object Text.UTF8Encoding $true)); return}
$name='双网分流-模块诊断-'+(Get-Date -Format yyyyMMdd-HHmmss)+'.txt'
$desktop=[Environment]::GetFolderPath('Desktop')
$file=if ($desktop -and (Test-Path -LiteralPath $desktop)) {Join-Path $desktop $name} else {Join-Path ([IO.Path]::GetTempPath()) $name}
[IO.File]::WriteAllLines($file,$report,(New-Object Text.UTF8Encoding $true))
Write-Host ('报告已保存到：'+$file)
Write-Host '请把这个文件发给开发者。'
try {Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"'+$file+'"')} catch {}
Read-Host '按回车关闭' | Out-Null
