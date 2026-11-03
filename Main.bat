@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
where powershell.exe >nul 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell is unavailable.
    pause
    exit /b 2
)
rem ExecutionPolicy applies to this single process only; no system setting is changed.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0BiliPack.ps1" %*
set "result=%ERRORLEVEL%"
echo.
if "%~1"=="" pause
exit /b %result%
