@echo off
chcp 65001 >nul
title FerIDE Beta v5.3.8 - Windows Otonom Kurulum Sihirbazı
echo ================================================================
echo   FerIDE Beta v5.3.8 - Windows 10/11 Otonom Kurulum Sihirbazı
echo ================================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kurulum.ps1" %*
echo.
if "%1"=="--autonomous" exit /b %ERRORLEVEL%
pause
