@echo off
setlocal
set "SCRIPT=%SystemRoot%\Web\Wallpaper\MeetRevision\WallpaperStartup.ps1"
if not exist "%SCRIPT%" (
    echo Wallpaper startup script was not found: "%SCRIPT%" 1>&2
    exit /b 1
)
PowerShell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%SCRIPT%"
exit /b %ERRORLEVEL%
