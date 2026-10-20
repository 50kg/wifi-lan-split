$ErrorActionPreference='Stop'
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Start-Process -FilePath $powershell -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$PSCommandPath+'"')
    exit
}
Write-Host '还原后，网线可以重新访问公网。' -ForegroundColor Yellow
Write-Host '会停止路由看守，恢复备份里的 DNS、接口开销和路由，并删除本工具的防火墙规则。'
Write-Host '建议先关闭需要固定公网出口的软件。'
$answer=Read-Host '输入 Y 并回车开始还原，直接回车取消'
if ($answer -notmatch '^\s*[Yy]\s*$') {
    Write-Host '已取消，没有修改任何设置。'
    Read-Host '按回车关闭' | Out-Null
    exit 1
}
& (Join-Path $PSScriptRoot 'backend.ps1') -Mode Restore -Console
