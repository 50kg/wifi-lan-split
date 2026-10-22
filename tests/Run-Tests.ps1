param([switch]$WriteReport)
# Safe local verification: syntax, build into a temp folder, isolated tests, and a UI layout preview with fictional data.
# Nothing here runs Setup/Restore/Renew/Repair or changes network settings.
# Continue, so a child process writing to stderr is reported as a failed check instead of aborting the run.
$ErrorActionPreference='Continue'
$project=Split-Path $PSScriptRoot -Parent
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$results=New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Name,[string]$Outcome,[string]$Detail) {
    $results.Add([pscustomobject]@{Check=$Name;Outcome=$Outcome;Detail=$Detail}) | Out-Null
    $color=if ($Outcome -eq 'PASS') {'Green'} elseif ($Outcome -eq 'SKIP') {'Yellow'} else {'Red'}
    Write-Host ('{0,-14} {1,-5} {2}' -f $Name,$Outcome,$Detail) -ForegroundColor $color
}

$scripts=@(Get-ChildItem $project -Recurse -Filter *.ps1 | Where-Object {$_.FullName -notmatch '\\(dist|build)\\'})
$bad=@(foreach ($f in $scripts) {
    $errors=$null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$null,[ref]$errors)
    $text=[IO.File]::ReadAllBytes($f.FullName)
    $bom=$text.Length -ge 3 -and $text[0] -eq 0xEF -and $text[1] -eq 0xBB -and $text[2] -eq 0xBF
    if (@($errors).Count) {$f.Name+': syntax'} elseif (-not $bom) {$f.Name+': no UTF-8 BOM'}
})
Add-Result 'Syntax' $(if ($bad.Count) {'FAIL'} else {'PASS'}) $(if ($bad.Count) {$bad -join '; '} else {[string]$scripts.Count+' scripts parse, all UTF-8 with BOM'})

$build=Join-Path ([IO.Path]::GetTempPath()) ('WifiLanSplit-build-'+[guid]::NewGuid().ToString('N'))
try {
    $out=& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'build.ps1') -OutputDirectory $build 2>&1
    Add-Result 'Build' $(if ($LASTEXITCODE -eq 0) {'PASS'} else {'FAIL'}) $(if ($LASTEXITCODE -eq 0) {'GUI and RouteGuard compile (temp folder)'} else {($out | Out-String).Trim()})

    $tests=@(@{Name='Test-Restore';Args=@()},@{Name='Test-Setup';Args=@()},@{Name='Test-Status';Args=@()},@{Name='Test-Guard';Args=@()},@{Name='Test-ModulePath';Args=@()},@{Name='Test-Engine';Args=@('-BuildOutput',$build);Admin=$true})
    foreach ($t in $tests) {
        if ($t.Admin -and -not $admin) {Add-Result $t.Name 'SKIP' 'needs an elevated PowerShell (sets folder owners in a temp folder)'; continue}
        $out=& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot ($t.Name+'.ps1')) @($t.Args) 2>&1
        $text=($out | Out-String).Trim()
        $pass=$LASTEXITCODE -eq 0 -and $text -match 'PASS '
        Add-Result $t.Name $(if ($pass) {'PASS'} else {'FAIL'}) $(if ($pass) {($text -split "`n" | Where-Object {$_ -match 'PASS '} | Select-Object -Last 1).Trim()} else {$text})
    }

    if ($admin) {
        # Once on this screen, once as if on a 1024x768 screen, where larger scales have to scroll.
        foreach ($case in @(@{Name='UI layout';Args=@();Label='this screen'},@{Name='UI small screen';Args=@('--screen','1024x768');Label='a 1024x768 screen'})) {
            $preview=Join-Path $build ('preview-'+[guid]::NewGuid().ToString('N'))
            $p=Start-Process -FilePath (Join-Path $build '双网分流.exe') -ArgumentList (@('--preview',('"'+$preview+'"'))+$case.Args) -PassThru
            if (-not $p.WaitForExit(150000)) {Stop-Process -Id $p.Id -Force; Add-Result $case.Name 'FAIL' 'preview did not finish'; continue}
            $report=(Get-Content (Join-Path $preview 'layout-report.txt') -Raw -Encoding UTF8).Trim()
            $shots=@(Get-ChildItem $preview -Filter *.png).Count
            Add-Result $case.Name $(if ($report -like 'no clipping*' -and $shots -ge 40) {'PASS'} else {'FAIL'}) ([string]$shots+' screenshots at 100-175% on '+$case.Label+': '+$report)
        }
    } else {Add-Result 'UI layout' 'SKIP' 'the GUI needs an elevated PowerShell'}
} finally {
    if (Test-Path -LiteralPath $build) {Remove-Item -LiteralPath $build -Recurse -Force -ErrorAction SilentlyContinue}
}

$failed=@($results | Where-Object Outcome -eq 'FAIL').Count
if ($WriteReport) {
    $files=@(Get-ChildItem (Join-Path $project 'src') -Recurse -File | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{File=$_.FullName.Substring($project.Length+1); SHA256=(Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash}
    })
    [pscustomobject]@{
        CheckedAt=(Get-Date -Format o); Passed=($failed -eq 0); Results=$results.ToArray()
        NetworkChangesPerformed=$false; LiveDeploymentChanged=$false; MachineBackupsOrCapturesCopied=$false
        Note='Isolated checks only: mocked network commands, fictional data, temp folders. Not a substitute for a real deployment, reboot or packet-capture test.'
        SourceFiles=$files
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $project 'docs\源码整理校验.json') -Encoding UTF8
}
if ($failed) {Write-Host ([string]$failed+' check(s) failed.') -ForegroundColor Red; exit 1}
Write-Host 'All checks passed. No network settings were changed.' -ForegroundColor Green
