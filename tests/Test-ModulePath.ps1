$ErrorActionPreference='Stop'
# A PowerShell 7 module path inherited by the backend made every check fail with
# "The 'Get-Acl' command was found in the module 'Microsoft.PowerShell.Security', but the module could not be loaded".
# A look-alike of PowerShell 7's Security module goes first on a child Windows PowerShell's path: without the backend the
# failure must reproduce, and with the backend dot-sourced only Windows PowerShell's own modules may load.
# Only temp folders are used; the backend is dot-sourced for its functions and runs nothing.
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$systemModules=Join-Path $PSHOME 'Modules'
try {
    # Like PowerShell 7's manifest, whose types file repeats members Windows PowerShell already defines, so loading it fails.
    $fake=Join-Path $TestRoot 'ps7\Modules\Microsoft.PowerShell.Security'
    New-Item -ItemType Directory -Force $fake | Out-Null
    Set-Content -LiteralPath (Join-Path $fake 'Microsoft.PowerShell.Security.psd1') -Encoding UTF8 -Value @(
        '@{'
        "ModuleVersion='7.0.0.0'"
        "CompatiblePSEditions=@('Core')"
        "CmdletsToExport='Get-Acl','Set-Acl'"
        "NestedModules='Microsoft.PowerShell.Security.dll'"
        "RequiredAssemblies='Microsoft.PowerShell.Security.dll'"
        "TypesToProcess='Security.types.ps1xml'"
        '}'
    )
    Set-Content -LiteralPath (Join-Path $fake 'Security.types.ps1xml') -Encoding UTF8 -Value '<Types><Type><Name>System.Security.AccessControl.ObjectSecurity</Name><Members><CodeProperty><Name>Path</Name><GetCodeReference><TypeName>Microsoft.PowerShell.Commands.SecurityDescriptorCommandsBase</TypeName><MethodName>GetPath</MethodName></GetCodeReference></CodeProperty></Members></Type></Types>'
    $folder=Join-Path $TestRoot 'folder'
    New-Item -ItemType Directory $folder | Out-Null
    # The child isolates itself the same way, then reads the folder's owner as Get-Status does.
    $probe=Join-Path $TestRoot 'probe.ps1'
    Set-Content -LiteralPath $probe -Encoding UTF8 -Value @(
        'param([string]$Support,[string]$Backend,[string]$Folder)'
        '. $Support'
        'try {'
        '    if ($Backend) {. $Backend; $null=Get-PathTrustProblem $Folder} else {$null=Get-Acl -LiteralPath $Folder}'
        '    ''LOADED ''+(Get-Module Microsoft.PowerShell.Security).Path'
        '    ''PATH ''+$env:PSModulePath'
        '} catch {''FAILED ''+$_.FullyQualifiedErrorId+'' ''+$_.Exception.Message} finally {Remove-TestRoot}'
    )
    $support=Join-Path $PSScriptRoot 'TestSupport.ps1'
    $saved=$env:PSModulePath
    try {
        $env:PSModulePath=(Split-Path $fake -Parent)+';'+$systemModules
        $plain=@(& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe -Support $support -Folder $folder)
        $backend=@(& $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe -Support $support -Backend (Join-Path $PSScriptRoot '..\src\powershell\backend.ps1') -Folder $folder)
    } finally {$env:PSModulePath=$saved}

    # 1. The look-alike really reproduces the reported failure; otherwise this test would prove nothing.
    Assert (@($plain | Where-Object {$_ -like 'FAILED CouldNotAutoloadMatchingModule*'}).Count -eq 1) ('Look-alike module did not reproduce the Get-Acl failure: '+($plain -join ' | '))
    # 2. With the backend, Security comes from Windows PowerShell's own folder.
    $loaded=@($backend | Where-Object {$_ -like 'LOADED *'})
    Assert ($loaded.Count -eq 1 -and $loaded[0].Substring(7).StartsWith($systemModules+'\',[StringComparison]::OrdinalIgnoreCase)) ('Backend did not load Security from Windows PowerShell: '+($backend -join ' | '))
    # 3. Nothing else is left on the path, the user's Documents module folder included.
    Assert (@($backend | Where-Object {$_ -eq ('PATH '+$systemModules)}).Count -eq 1) ('Backend module path is not only Windows PowerShell''s own folder: '+($backend -join ' | '))

    # A module that cannot load must name its cause in the backend's failure message, which is what the log shows.
    . (Join-Path $PSScriptRoot '..\src\powershell\backend.ps1')
    $Root=Join-Path $TestRoot 'backend-root'; $StateFile=Join-Path $Root 'state.json'
    Use-TestRoot
    $mods=Join-Path $TestRoot 'mods'
    function New-TestModule([string]$Name,[string]$Body) {
        $dir=Join-Path $mods $Name
        New-Item -ItemType Directory -Force $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir ($Name+'.psd1')) -Encoding UTF8 -Value ("@{ModuleVersion='1.0'; RootModule='"+$Name+".psm1'; FunctionsToExport='Get-"+$Name+"'}")
        Set-Content -LiteralPath (Join-Path $dir ($Name+'.psm1')) -Encoding UTF8 -Value @($Body,('function Get-'+$Name+' {}'))
    }
    function Get-Failure([scriptblock]$Block) {try {& $Block; ''} catch {Get-FailureMessage $_}}
    New-TestModule 'WlsWrites' "Write-Error 'stand-in import error'"
    New-TestModule 'WlsThrows' "throw 'stand-in import exception'"
    $once=Join-Path $TestRoot 'failed-once'
    New-TestModule 'WlsPassing' ("if (-not (Test-Path -LiteralPath '"+$once+"')) {New-Item -ItemType File -Path '"+$once+"' | Out-Null; Write-Error 'stand-in passing error'}")
    $env:PSModulePath+=';'+$mods
    # 4. An error that $ErrorActionPreference made fatal during the import is not attached to the failure; it is still named.
    $m=Get-Failure {Get-WlsWrites}
    Assert ($m -like '*WlsWrites*（原因：*stand-in import error*）') ('Failure message lacks the import error: '+$m)
    # 5. An exception thrown by the import is named.
    $m=Get-Failure {Get-WlsThrows}
    Assert ($m -like '*WlsThrows*（原因：*stand-in import exception*）') ('Failure message lacks the import exception: '+$m)
    # 6. A module that loads on the second try is reported as passing.
    $m=Get-Failure {Get-WlsPassing}
    Assert ($m -like '*WlsPassing*（原因：再次加载 WlsPassing 成功*）') ('Passing import failure not reported: '+$m)
    # 7. Any other failure keeps its message as it is.
    $m=Get-Failure {throw '另一项操作正在进行，请等它完成后再试。'}
    Assert ($m -eq '另一项操作正在进行，请等它完成后再试。') ('Plain failure message changed: '+$m)
    Write-Output 'PASS Test-ModulePath: a PowerShell 7 Security module ahead on the path reproduces the Get-Acl failure; the backend loads modules only from Windows PowerShell''s own folder; failure messages name why a module did not load (import error, exception, passing error) and leave other messages unchanged.'
} finally {Remove-TestRoot}
