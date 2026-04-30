@echo off
REM Launcher for Map-NetworkDrives.ps1.
REM Bypasses PowerShell ExecutionPolicy for this single invocation only;
REM does not change any persistent system settings. Forwards all arguments
REM to the script (e.g. -Silent, -Detailed, -DryRun, -TimeoutMs, -Parallelism).
REM
REM Auto-update: if this folder is a git working tree and git + network are
REM available, the launcher fast-forwards to origin before invoking the
REM PowerShell script — so updates to Map-NetworkDrives.ps1 take effect on
REM the same run. Pass -NoUpdate to skip. Installs Git.Git via winget on
REM first use if git is missing and winget is available.

setlocal
cd /d "%~dp0"

set "NO_UPDATE="
for %%A in (%*) do if /i "%%~A"=="-NoUpdate" set "NO_UPDATE=1"

if not defined NO_UPDATE if exist ".git\HEAD" call :TryUpdate

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Map-NetworkDrives.ps1" %*

REM Pause only when double-clicked from Explorer (so output stays visible);
REM stay silent when invoked from an existing cmd/PowerShell session.
echo %cmdcmdline% | findstr /i /c:"%~nx0" >nul
if %errorlevel% equ 0 pause
endlocal
goto :eof

:TryUpdate
where git >nul 2>&1
if errorlevel 1 call :InstallGit
where git >nul 2>&1
if errorlevel 1 (
    echo [auto-update] git not available; skipping.
    goto :eof
)
git fetch --quiet origin 2>nul
if errorlevel 1 (
    REM Origin unreachable or no upstream configured — silent skip (offline run).
    goto :eof
)
git pull --ff-only --quiet 2>nul
if errorlevel 1 (
    echo [auto-update] Local branch has diverged from origin; skipping.
    echo                Run 'git status' to investigate, or
    echo                'git reset --hard origin/main' to discard local changes.
    goto :eof
)
goto :eof

:InstallGit
where winget >nul 2>&1
if errorlevel 1 (
    echo [auto-update] git not installed and winget unavailable; skipping.
    goto :eof
)
echo [auto-update] Installing Git via winget (one-time setup)...
winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
goto :eof
