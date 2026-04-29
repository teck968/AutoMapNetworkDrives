@echo off
REM Launcher for Test-Discovery.ps1.
REM Bypasses PowerShell ExecutionPolicy for this single invocation only;
REM does not change any persistent system settings.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-Discovery.ps1" %*

REM Pause only when double-clicked from Explorer (so output stays visible);
REM stay silent when invoked from an existing cmd/PowerShell session.
echo %cmdcmdline% | findstr /i /c:"%~nx0" >nul
if %errorlevel% equ 0 pause
