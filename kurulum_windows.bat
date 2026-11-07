@echo off
chcp 65001 >nul
title FerIDE - Windows Kurulumu
echo ================================================================
echo   FerIDE Beta v5.3.8 - Windows 10/11 Kurulumu
echo ================================================================
echo.
if /i "%~1"=="--autonomous" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kurulum.ps1" -Autonomous
    exit /b %ERRORLEVEL%
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kurulum.ps1" -Launch
echo.
pause
