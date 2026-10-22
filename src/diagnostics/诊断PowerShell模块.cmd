@echo off
rem Read-only: writes a report on where Windows PowerShell finds its modules to the desktop. Changes no setting.
rem Windows PowerShell rewrites PSModulePath when it starts, so pass on the value this window has.
set "WLS_DIAG_FROM_CMD=1"
set "WLS_DIAG_PSMODULEPATH=%PSModulePath%"
if not defined PSModulePath set "WLS_DIAG_PSMODULEPATH_UNSET=1"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0diagnose-powershell-modules.ps1"
