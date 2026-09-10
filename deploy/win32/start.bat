@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================
echo  nginx-rtc HTTP-FLV live streaming (Windows)
echo ============================================
echo.

nginx.exe -t -p .
if errorlevel 1 (
    echo [ERROR] config test failed, see logs\error.log
    pause
    exit /b 1
)

start "nginx-rtc" nginx.exe -p .
echo [OK] nginx started.
echo.
echo   RTMP push:   rtmp://127.0.0.1:1935/live/STREAM
echo   Push test:   double-click push_test.bat
echo   HTTP-FLV:    http://127.0.0.1:18082/live?app=live^&stream=STREAM
echo   Play page:   http://127.0.0.1:18082/flvplayer
echo.
echo   Stop:        double-click stop.bat
echo.
pause
