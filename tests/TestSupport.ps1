# Dot-source this first in every test.
# Every network, firewall, DNS, adapter and scheduled-task command is replaced by a function that throws,
# so a command the test forgot to mock fails the test instead of reaching the real system.
$ErrorActionPreference='Stop'
$TestRoot=Join-Path ([IO.Path]::GetTempPath()) ('WifiLanSplit-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $TestRoot | Out-Null
foreach ($command in @(Get-Command -Module NetSecurity,NetTCPIP,DnsClient,NetAdapter,ScheduledTasks -ErrorAction Stop)) {
    Set-Item -Path ('function:'+$command.Name) -Value ([scriptblock]::Create("throw 'Test isolation: unmocked command $($command.Name)'"))
}
foreach ($name in @('netsh','netsh.exe','ipconfig','ipconfig.exe','icacls','icacls.exe','route','route.exe','schtasks','schtasks.exe','Stop-Process','Wait-Process','Get-CimInstance','Stop-Service','Restart-Service','Set-Service','Invoke-BlockedExe')) {
    Set-Item -Path ('function:'+$name) -Value ([scriptblock]::Create("throw 'Test isolation: unmocked command $name'"))
}
try {Get-NetRoute | Out-Null; throw 'Test isolation is not active'} catch {if ($_.Exception.Message -notlike 'Test isolation: unmocked*') {throw}}
function Assert($Condition,[string]$Message) {if (-not $Condition) {throw ('FAIL: '+$Message)}}
function Remove-TestRoot {if (Test-Path -LiteralPath $TestRoot) {Remove-Item -LiteralPath $TestRoot -Recurse -Force}}
# Call after dot-sourcing the scripts under test and pointing them at the temp folder.
# The scripts call netsh and ipconfig by full path, which a function cannot shadow, so those paths are blocked here;
# a test that needs one assigns its own mock afterwards.
function Use-TestRoot {
    foreach ($name in 'Root','StateFile') {
        $value=Get-Variable -Name $name -Scope 1 -ValueOnly -ErrorAction SilentlyContinue
        if ($value -and -not ([string]$value).StartsWith($TestRoot,[StringComparison]::OrdinalIgnoreCase)) {throw ('Test isolation: $'+$name+' points outside the test folder: '+$value)}
    }
    Set-Variable -Name NetshExe -Value 'Invoke-BlockedExe' -Scope 1
    Set-Variable -Name IpconfigExe -Value 'Invoke-BlockedExe' -Scope 1
}
