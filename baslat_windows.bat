@echo off
chcp 65001 >nul
rem FerIDE Windows başlatıcı. Uygulama bu bilgisayarda henüz derlenmemişse
rem kurulumu kendisi başlatır; kurulum bitince FerIDE açılır.
set "FERIDE_ROOT=%~dp0"
if "%FERIDE_ROOT:~-1%"=="\" set "FERIDE_ROOT=%FERIDE_ROOT:~0,-1%"
cd /d "%FERIDE_ROOT%"
set "PATH=%USERPROFILE%\.feride\bin\llama-cpp;%USERPROFILE%\.feride\venv\Scripts;%PATH%"

set "WIN_EXE=%FERIDE_ROOT%\build\windows\x64\runner\Release\feride_v5_2.exe"
if exist "%WIN_EXE%" (
    start "" /D "%FERIDE_ROOT%" "%WIN_EXE%"
    exit /b 0
)

echo [FerIDE] Uygulama bu bilgisayarda henüz kurulmamış; kurulum başlatılıyor...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%FERIDE_ROOT%\kurulum.ps1" -Launch
if not exist "%WIN_EXE%" (
    echo.
    echo [FerIDE] Uygulama hazırlanamadı. Ayrıntılar: %USERPROFILE%\.feride\logs\kurulum_windows.log
    pause
)
