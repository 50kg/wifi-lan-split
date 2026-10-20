param([ValidateSet('View','Cancel')][string]$Mode='View')
$ErrorActionPreference='Stop'
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Mode '+$Mode)
    exit
}
Add-Type -AssemblyName System.Windows.Forms
$folder=Join-Path $env:ProgramData 'WifiLanSplit/PostBoot'
if ($Mode -eq 'Cancel') {
    $task=Get-ScheduledTask -TaskName WifiLanPostBootAudit -ErrorAction SilentlyContinue
    if ($task) {Stop-ScheduledTask -TaskName $task.TaskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false}
    [System.Windows.Forms.MessageBox]::Show('已取消开机自动检查。现有路由看守和分流规则保持不变。','双网分流') | Out-Null
    exit
}
$report=Join-Path $folder 'latest-report.txt'
if (Test-Path $report) {Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"'+$report+'"');exit}
[System.Windows.Forms.MessageBox]::Show('重启后的正式报告尚未生成。请保持手机热点 Wi-Fi 和公司网线连接，网络就绪后等待约 1 分钟；自动检查最长等待 10 分钟。','双网分流') | Out-Null
