$ErrorActionPreference='Stop'
# Simulates updating and repairing the route guard: task, process and heartbeat are fictional; files live in a temp folder.
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
. (Join-Path $PSScriptRoot '..\src\powershell\backend.ps1')
$Root=Join-Path $TestRoot 'root'; $Package=Join-Path $TestRoot 'package'; $StateFile=Join-Path $Root 'state.json'
New-Item -ItemType Directory -Force $Root,$Package | Out-Null
Use-TestRoot
$ethGuid='{22222222-2222-2222-2222-222222222222}'
$eth=[pscustomobject]@{ifIndex=12;InterfaceGuid=$ethGuid}
$target=Join-Path $Root 'RouteGuard.exe'; $heartbeat=Join-Path $Root 'guard-heartbeat.txt'
$script:ops=New-Object 'System.Collections.Generic.List[object]'
function Record-Test($name,$data) {$script:ops.Add([pscustomobject]@{Name=$name;Data=$data}) | Out-Null}
function Names {($script:ops | ForEach-Object Name) -join ','}

function Get-ItemProperty($Path) {[pscustomobject]@{MachineGuid='synthetic'}}
function Get-PathTrustProblem([string]$Path) {''}
function Set-NetIPInterface($InterfaceIndex,$AddressFamily,$IgnoreDefaultRoutes) {Record-Test 'IgnoreDefaultRoutes' $IgnoreDefaultRoutes}
function Get-NetRoute($InterfaceIndex,$AddressFamily,$DestinationPrefix,$ErrorAction) {}
function Get-ScheduledTask($TaskName,$ErrorAction) {
    if ($script:task) {[pscustomobject]@{State=$script:task.State;Actions=@([pscustomobject]@{Execute=$script:task.Execute;Arguments=$script:task.Arguments})}}
}
function Stop-ScheduledTask($TaskName,$ErrorAction) {
    Record-Test 'StopTask' ([pscustomobject]@{NewCopyReady=(Test-Path ($target+'.new')) -or $script:replaceNotNeeded})
    # A hung guard that no longer belongs to the task survives Stop-ScheduledTask and must be ended by process.
    if ($script:task) {$script:task.State='Ready'}; if (-not $script:orphan) {$script:process=$false}
}
function Start-ScheduledTask($TaskName) {
    Record-Test 'StartTask' $null
    $script:task.State='Running'; $script:process=$true
    if (-not $script:failStart) {Set-Content -LiteralPath $heartbeat (Get-Date -Format o)}
}
function Unregister-ScheduledTask($TaskName,[switch]$Confirm) {Record-Test 'Unregister' $null; $script:task=$null}
function New-ScheduledTaskAction($Execute,$Argument,$WorkingDirectory) {[pscustomobject]@{Execute=$Execute;Arguments=$Argument}}
function New-ScheduledTaskPrincipal {'principal'}
function New-ScheduledTaskSettingsSet {'settings'}
function New-ScheduledTaskTrigger {'trigger'}
function Register-ScheduledTask($TaskName,$Action,$Trigger,$Principal,$Settings,$Description) {Record-Test 'Register' $Action; $script:task=@{State='Ready';Execute=$Action.Execute;Arguments=$Action.Arguments}}
function Get-CimInstance($ClassName,$Filter) {if ($script:process) {[pscustomobject]@{ProcessId=4242;ExecutablePath=$target}}}
function Stop-Process($Id,[switch]$Force,$ErrorAction) {Record-Test 'Kill' $Id; $script:process=$false}
function Wait-Process($Id,$Timeout,$ErrorAction) {}

function Set-World([string]$Deployed='old build',[string]$Packaged='new build',[string]$Execute=$target,[switch]$StaleHeartbeat,[switch]$FailStart,[switch]$Orphan) {
    $script:ops.Clear()
    Get-ChildItem -LiteralPath $Root -Force | Remove-Item -Force -Recurse
    [pscustomobject]@{Version=2;Status='Applied';MachineGuid='synthetic';Ethernet=@{Guid=$ethGuid}} | ConvertTo-Json | Set-Content -Encoding UTF8 $StateFile
    Set-Content -LiteralPath $target $Deployed
    Set-Content -LiteralPath (Join-Path $Package 'RouteGuard.exe') $Packaged
    Set-Content -LiteralPath $heartbeat 'beat'
    if ($StaleHeartbeat) {(Get-Item -LiteralPath $heartbeat).LastWriteTime=(Get-Date).AddMinutes(-5)}
    $script:task=@{State='Running';Execute=$Execute;Arguments=('--watch '+$ethGuid+' "'+$Root+'"')}
    $script:process=$true; $script:failStart=[bool]$FailStart; $script:orphan=[bool]$Orphan; $script:replaceNotNeeded=$Deployed -eq $Packaged
}

try {
    # 1. Update: the new copy is ready before the old guard stops; the task stays registered.
    Set-World
    Install-Guard $eth
    Assert ((Get-Content -LiteralPath $target -Raw).Trim() -eq 'new build') 'U1: the new guard was not deployed'
    $stop=@($script:ops | Where-Object Name -eq StopTask)
    Assert ($stop.Count -ge 1 -and $stop[0].Data.NewCopyReady) 'U1: the old guard was stopped before the new copy was ready'
    Assert ((Names) -notmatch 'Unregister|Register') ('U1: the task was re-registered: '+(Names))
    Assert ((Names) -match 'StartTask') 'U1: the guard was not started again'
    Assert (-not (Test-Path ($target+'.new')) -and -not (Test-Path ($target+'.old'))) 'U1: temporary copies left behind'

    # 2. A failed swap puts the old program back and starts it.
    Set-World
    function Move-Item {param($LiteralPath,$Destination) if ($LiteralPath -like '*.new') {throw 'file in use'}; Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination}
    $err=''; try {Install-Guard $eth} catch {$err=$_.Exception.Message}
    Remove-Item function:Move-Item
    Assert ($err -like '*已放回原来的程序*') ('U2: swap failure not reported: '+$err)
    Assert ((Get-Content -LiteralPath $target -Raw).Trim() -eq 'old build') 'U2: the old guard was not put back'
    Assert ((Names) -match 'StartTask' -and (Names) -notmatch 'Unregister') ('U2: the old guard was not restarted with its task: '+(Names))

    # 3. Same build, task running, heartbeat stale: end the stuck process and start again.
    Set-World -Deployed 'same' -Packaged 'same' -StaleHeartbeat -Orphan
    Install-Guard $eth
    Assert ((Names) -match 'Kill' -and (Names) -match 'StartTask') ('R3: a stuck guard was not restarted: '+(Names))

    # 4. Same build, running, fresh heartbeat: nothing is stopped or started.
    Set-World -Deployed 'same' -Packaged 'same'
    Install-Guard $eth
    Assert ((Names) -notmatch 'StopTask|StartTask|Kill|Register') ('R4: a healthy guard was disturbed: '+(Names))

    # 5. A task that runs something else is replaced.
    Set-World -Deployed 'same' -Packaged 'same' -Execute 'C:\Elsewhere\RouteGuard.exe'
    Install-Guard $eth
    Assert ((Names) -match 'Unregister' -and (Names) -match 'Register' -and (Names) -match 'StartTask') ('R5: a task pointing elsewhere was kept: '+(Names))
    Assert ($script:task.Execute -eq $target) 'R5: the new task does not run the deployed guard'

    # 6. A guard that never writes a heartbeat after the restart is reported, even though an old heartbeat exists.
    Set-World -FailStart
    $err=''; try {Install-Guard $eth} catch {$err=$_.Exception.Message}
    Assert ($err -like '*没有通过启动检查*') ('R6: a guard that did not start was accepted: '+$err)
    Write-Output 'PASS Test-Guard: update keeps the task and stages the copy first, failed swap restores the old guard, stuck guard restarted, healthy guard untouched, foreign task replaced, old heartbeat not accepted.'
} finally {Remove-TestRoot}
