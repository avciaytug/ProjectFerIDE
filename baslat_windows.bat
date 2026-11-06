@echo off
chcp 65001 >nul
set "FERIDE_ROOT=%~dp0"
if "%FERIDE_ROOT:~-1%"=="\" set "FERIDE_ROOT=%FERIDE_ROOT:~0,-1%"
cd /d "%FERIDE_ROOT%"

set "WIN_EXE=%FERIDE_ROOT%\build\windows\x64\runner\Release\feride_v5_2.exe"
if exist "%WIN_EXE%" (
    start "" "%WIN_EXE%"
    exit /b 0
)

where flutter >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    echo [FerIDE] İlk Windows Release derlemesi yapılıyor...
    call flutter pub get
    call flutter build windows --release
    if exist "%WIN_EXE%" (
        start "" "%WIN_EXE%"
        exit /b 0
    )
)

echo [FerIDE] Windows çalıştırılabilir paketi (feride_v5_2.exe) henüz derlenmemiş.
echo Lütfen Flutter Windows SDK kurulu bir ortamda 'kurulum_windows.bat' çalıştırın.
pause
