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

REM If TryUpdate pulled an update to this .cmd, re-launch ourselves with the
REM new content so the rest of execution doesn't depend on cmd.exe's behavior
REM around mid-execution file changes (cmd re-reads the script at certain
REM control-flow boundaries; safer to start fresh). Run #2 inherits the same
REM console window via cmd /c, so all output stays in chronological order in
REM one place. -NoUpdate prevents an infinite loop and skips the redundant
REM second fetch.
REM
REM Use single-line `if defined` instead of an `if (...)` parens block:
REM inside a parens block, %~f0 and %* are parse-time expanded along with
REM the rest of the block, which has caused "The input line is too long."
REM / "The syntax of the command is incorrect." errors in practice. Single-
REM line ifs expand at execute time and behave reliably.
if defined AU_RELAUNCH goto :Relaunch
goto :SkipRelaunch
:Relaunch
REM Invoke the .cmd via its path. Windows' .cmd handler spawns a fresh
REM cmd.exe to interpret the file, giving us a clean parser state — this
REM is what we want to sidestep cmd's mid-execution file re-read behavior.
REM Plain "%~f0" %* args avoids cmd /c's quote-stripping rules entirely
REM (the earlier "cmd /c ""%~f0" %* -NoUpdate"" form produced "input
REM line too long." / "syntax incorrect." errors when invoked from a
REM child cmd, despite the same form working when invoked directly).
"%~f0" %* -NoUpdate
exit /b
:SkipRelaunch

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Map-NetworkDrives.ps1" %*

REM Pause only when double-clicked from Explorer (so output stays visible);
REM stay silent when invoked from an existing cmd/PowerShell session.
echo %cmdcmdline% | findstr /i /c:"%~nx0" >nul
if %errorlevel% equ 0 pause
endlocal
goto :eof

:TryUpdate
where git >nul 2>&1
if errorlevel 1 (
    set "AU_INSTALLED_GIT="
    call :InstallGit
)
where git >nul 2>&1
if errorlevel 1 (
    if defined AU_INSTALLED_GIT (
        echo [auto-update] Git was installed but isn't visible to this session yet. Re-run the launcher to pick up the update.
    ) else (
        echo [auto-update] git not available; skipping.
    )
    goto :eof
)
git fetch --quiet origin 2>nul
if errorlevel 1 (
    REM Origin unreachable or no upstream configured — silent skip (offline run).
    goto :eof
)
for /f "delims=" %%H in ('git rev-parse HEAD 2^>nul') do set "AU_BEFORE=%%H"
git pull --ff-only --quiet 2>nul
if errorlevel 1 (
    echo [auto-update] Local branch has diverged from origin; skipping.
    echo                Run 'git status' to investigate, or
    echo                'git reset --hard origin/main' to discard local changes.
    goto :eof
)
for /f "delims=" %%H in ('git rev-parse HEAD 2^>nul') do set "AU_AFTER=%%H"
if not "%AU_BEFORE%"=="%AU_AFTER%" (
    echo [auto-update] Updated to %AU_AFTER:~0,7%.
    echo [auto-update] Re-launching with the new version...
    set "AU_RELAUNCH=1"
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
if errorlevel 1 (
    echo [auto-update] winget install failed (exit %errorlevel%); skipping.
    goto :eof
)
set "AU_INSTALLED_GIT=1"
REM winget updates the system PATH, but our running cmd session inherited
REM PATH at start and won't see the change. Prepend Git for Windows's
REM standard install locations so the next 'where git' check in this
REM session can find the freshly installed binary.
if exist "%ProgramFiles%\Git\cmd\git.exe"          set "PATH=%ProgramFiles%\Git\cmd;%PATH%"
if exist "%ProgramFiles(x86)%\Git\cmd\git.exe"     set "PATH=%ProgramFiles(x86)%\Git\cmd;%PATH%"
if exist "%LocalAppData%\Programs\Git\cmd\git.exe" set "PATH=%LocalAppData%\Programs\Git\cmd;%PATH%"
goto :eof
