@echo off
REM Launcher for Map-NetworkDrives.ps1.
REM Bypasses PowerShell ExecutionPolicy for this single invocation only;
REM does not change any persistent system settings. Forwards all arguments
REM to the script (e.g. -Silent, -WhatIf, -TimeoutMs, -Parallelism).

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Map-NetworkDrives.ps1" %*

REM Pause only when double-clicked from Explorer (so output stays visible);
REM stay silent when invoked from an existing cmd/PowerShell session or by
REM Task Scheduler.
echo %cmdcmdline% | findstr /i /c:"%~nx0" >nul
if %errorlevel% equ 0 pause
