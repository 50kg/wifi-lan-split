param([Parameter(Mandatory=$true)][string]$BuildOutput)
$ErrorActionPreference='Stop'
# Exercises the GUI's file-integrity and data-folder code in a temp folder. Nothing outside the temp folder is touched.
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$asm=[Reflection.Assembly]::LoadFrom((Join-Path $BuildOutput '双网分流.exe'))
$engine=$asm.GetType('Engine',$true)
function Invoke-Engine([string]$Method,[object[]]$Arguments) {
    $plain=New-Object 'object[]' $Arguments.Count
    for ($i=0; $i -lt $Arguments.Count; $i++) {$plain[$i]=[string]$Arguments[$i]}
    try {$engine.GetMethod($Method).Invoke($null,$plain)} catch {$e=$_.Exception; while ($e.InnerException) {$e=$e.InnerException}; throw $e}
}
. (Join-Path $PSScriptRoot '..\src\powershell\backend.ps1')
$Root=Join-Path $TestRoot 'backend-root'; $StateFile=Join-Path $Root 'state.json'
Use-TestRoot
try {
    # 1. A missing data folder is created already locked to SYSTEM and Administrators, and the backend agrees it is safe.
    $root=Join-Path $TestRoot 'WifiLanSplit'
    $copied=Invoke-Engine 'Prepare' @($root,$BuildOutput)
    Assert ((Get-PathTrustProblem $root) -eq '') 'New data folder is not locked down'
    $acl=Get-Acl $root
    Assert ($acl.AreAccessRulesProtected) 'New data folder still inherits permissions'
    foreach ($name in 'backend.ps1','network-core.ps1','RouteGuard.exe') {
        Assert ((Get-FileHash (Join-Path $copied $name)).Hash -eq (Get-FileHash (Join-Path $BuildOutput $name)).Hash) ($name+' was not copied unchanged')
    }

    # 2. A folder with loose permissions but a trusted owner is tightened.
    $loose=Join-Path $TestRoot 'loose'
    New-Item -ItemType Directory $loose | Out-Null
    $acl=Get-Acl $loose
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'),'Modify','ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl $loose $acl
    Assert ((Get-PathTrustProblem $loose) -like 'S-1-5-32-545*') 'Backend did not notice a writable folder'
    Invoke-Engine 'EnsureRoot' @($loose) | Out-Null
    Assert ((Get-PathTrustProblem $loose) -eq '') 'GUI did not tighten a loose folder'

    # 3. The backend's own folder setup does the same for a missing folder.
    Initialize-Root
    Assert ((Get-PathTrustProblem $Root) -eq '' -and (Get-Acl $Root).AreAccessRulesProtected) 'Backend did not create a locked data folder'

    # 4. A modified backend file is refused and never copied.
    $package=Join-Path $TestRoot 'package'
    Copy-Item $BuildOutput $package -Recurse
    Add-Content -LiteralPath (Join-Path $package 'backend.ps1') '# tampered'
    $root2=Join-Path $TestRoot 'WifiLanSplit2'
    $err=''; try {Invoke-Engine 'Prepare' @($root2,$package) | Out-Null} catch {$err=$_.Exception.Message}
    Assert ($err -like '*backend.ps1*') 'Modified backend.ps1 was accepted'
    Assert (-not (Test-Path (Join-Path $root2 'app\backend.ps1'))) 'Modified backend.ps1 was copied'

    # 5. A missing file is refused with its name.
    Copy-Item (Join-Path $BuildOutput 'backend.ps1') (Join-Path $package 'backend.ps1') -Force
    Remove-Item (Join-Path $package 'RouteGuard.exe')
    $err=''; try {Invoke-Engine 'Prepare' @($root2,$package) | Out-Null} catch {$err=$_.Exception.Message}
    Assert ($err -like '*RouteGuard.exe*') 'Missing file not reported'
    Write-Output 'PASS Test-Engine: locked data folder (GUI and backend), loose folder tightened, verified copy, tampered and missing files refused.'
} finally {Remove-TestRoot}
