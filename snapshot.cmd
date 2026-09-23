@echo off
setlocal
pushd "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
    echo   [ERROR] Windows PowerShell not found - cannot create a snapshot.
    pause
    popd
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0snapshot.ps1"

pause
popd
endlocal
