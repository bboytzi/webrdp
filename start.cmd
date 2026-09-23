@echo off
setlocal
set "ROOT=%~dp0"
pushd "%ROOT%"

REM ---- all settings live in .env (same format on Windows and Linux) ----
REM Only NODE_EXE and PORT are read here; server.js reads the rest itself.
set "NODE_EXE="
set "ENV_PORT="
set "ENV_FILE=%ROOT%.env"
if exist "%ENV_FILE%" (
    for /f "usebackq eol=# tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
        if /i "%%A"=="NODE_EXE" set "NODE_EXE=%%B"
        if /i "%%A"=="PORT" set "ENV_PORT=%%B"
    )
)

REM Command line wins over .env
if not "%~1"=="" set "PORT=%~1"
if not defined PORT set "PORT=%ENV_PORT%"
if not defined PORT set "PORT=8080"

REM ---- locate node ----
if not defined NODE_EXE if exist "%ROOT%runtime\node.exe" set "NODE_EXE=%ROOT%runtime\node.exe"

if not defined NODE_EXE (
    for /f "delims=" %%I in ('where node 2^>nul') do (
        if not defined NODE_EXE set "NODE_EXE=%%I"
    )
)

if not defined NODE_EXE if exist "C:\Program Files\nodejs\node.exe" set "NODE_EXE=C:\Program Files\nodejs\node.exe"
if not defined NODE_EXE if exist "C:\Program Files (x86)\nodejs\node.exe" set "NODE_EXE=C:\Program Files (x86)\nodejs\node.exe"
if not defined NODE_EXE if exist "%LOCALAPPDATA%\Programs\nodejs\node.exe" set "NODE_EXE=%LOCALAPPDATA%\Programs\nodejs\node.exe"

if not defined NODE_EXE (
    echo.
    echo   [ERROR] Node.js was not found.
    echo.
    echo   Install Node.js LTS from https://nodejs.org/ and run this again, or
    echo     - drop a standalone node.exe into: %ROOT%runtime\
    echo     - or set NODE_EXE=full\path\to\node.exe in %ROOT%.env
    echo.
    pause
    popd
    exit /b 1
)

if exist "%ROOT%config.cmd" echo   [warn] config.cmd is no longer used - settings now live in .env

echo.
echo   webrdp - browser-based RDP gateway
echo   ----------------------------------
echo   node     : %NODE_EXE%
echo   port     : %PORT%
if exist "%ENV_FILE%" echo   config   : .env
if not exist "%ENV_FILE%" echo   config   : .env NOT FOUND - copy .env.example to .env and edit it
echo   this PC  : http://127.0.0.1:%PORT%/
echo   LAN      : http://(this-pc-ip):%PORT%/   - needs inbound TCP %PORT% allowed
echo.
echo   Optional: "start.cmd 8081" overrides the port.
echo   Press Ctrl+C to stop.
echo.

"%NODE_EXE%" server.js

echo.
echo   Server stopped.
pause
popd
endlocal
