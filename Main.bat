@echo off
setlocal
set "SCRIPT=%~dp0BiliPack.ps1"
if not exist "%SCRIPT%" (
    echo BiliPack.ps1 was not found beside Main.bat.
    pause
    exit /b 2
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "CODE=%ERRORLEVEL%"
echo.
pause
exit /b %CODE%
