@echo off
setlocal enableextensions
cd /d "%~dp0"
set "LOG=%~dp0installer-log.txt"
set "BAT=%~f0"
title OT2 MOD Installer

echo [%DATE% %TIME%] ---- launcher start ---- >> "%LOG%"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
echo [%DATE% %TIME%] powershell: %PS% >> "%LOG%"

if /i "%~1"=="--noelevate" goto RUN

rem ---- writing into the Steam folder needs administrator rights ----
whoami /groups 2>nul | findstr /C:"S-1-16-12288" >nul
if errorlevel 1 (
    echo Requesting administrator rights - please click YES in the UAC prompt.
    echo [%DATE% %TIME%] elevation requested >> "%LOG%"
    "%PS%" -NoProfile -Command "try { Start-Process -FilePath '%BAT%' -Verb RunAs -ErrorAction Stop } catch { Write-Host 'ELEVATION FAILED:' $_.Exception.Message; Write-Host 'Try: right-click the .bat -> Run as administrator'; Start-Sleep -Seconds 8 }"
    exit /b
)

:RUN
echo Starting the installer window, please wait a moment...
echo [%DATE% %TIME%] running installer.ps1 >> "%LOG%"
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0installer.ps1" 2>>"%LOG%"
set "RC=%errorlevel%"
echo [%DATE% %TIME%] installer.ps1 exited with code %RC% >> "%LOG%"

rem ---- normal exit (you closed the installer window): close this window too, right away ----
if "%RC%"=="0" goto DONE

echo.
echo [The installer ended with an error - this window stays open so you can read it.]
echo Log file: "%LOG%"
echo.
pause

:DONE
endlocal
