@echo off
chcp 65001 >nul
rem FerIDE Windows başlatıcı. Uygulama bu bilgisayarda henüz derlenmemişse
rem kurulumu kendisi başlatır; kurulum bitince FerIDE açılır.
set "FERIDE_ROOT=%~dp0"
if "%FERIDE_ROOT:~-1%"=="\" set "FERIDE_ROOT=%FERIDE_ROOT:~0,-1%"
cd /d "%FERIDE_ROOT%"
set "PATH=%USERPROFILE%\.feride\bin\llama-cpp;%USERPROFILE%\.feride\venv\Scripts;%PATH%"

set "REL=%FERIDE_ROOT%\build\windows\x64\runner\Release"
set "WIN_EXE=%REL%\feride_v5_2.exe"
rem Kaynak (yeni zip) derlenen uygulamadan yeniyse önce yeniden derlenir.
set "CURRENT=1"
if not exist "%WIN_EXE%" set "CURRENT=0"
if exist "%FERIDE_ROOT%\KAYNAK_SURUMU.txt" (
    fc /b "%FERIDE_ROOT%\KAYNAK_SURUMU.txt" "%REL%\KAYNAK_SURUMU.txt" >nul 2>nul || set "CURRENT=0"
)
if "%CURRENT%"=="1" (
    start "" /D "%FERIDE_ROOT%" "%WIN_EXE%"
    exit /b 0
)

echo [FerIDE] Uygulama bu bilgisayarda henüz kurulmamış ya da güncellenmesi gerekiyor; kurulum başlatılıyor...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%FERIDE_ROOT%\kurulum.ps1" -Launch
if not exist "%WIN_EXE%" (
    echo.
    echo [FerIDE] Uygulama hazırlanamadı. Ayrıntılar: %USERPROFILE%\.feride\logs\kurulum_windows.log
    pause
)
