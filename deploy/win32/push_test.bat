@echo off
chcp 65001 >nul

set "FF=%~dp0tools\ffmpeg.exe"
if not exist "%FF%" (
    echo [ERROR] 未找到 %FF%
    pause
    exit /b 1
)

echo 开始推测试流到 live/livestream（彩色测试图案 + 正弦音）...
echo 保持本窗口运行，按 Ctrl+C 停止推流。
echo.

"%FF%" -re -f lavfi -i testsrc=size=640x360:rate=25 ^
        -f lavfi -i sine=frequency=440:sample_rate=44100 ^
        -c:v libx264 -preset veryfast -tune zerolatency -b:v 800k -pix_fmt yuv420p ^
        -c:a aac -b:a 96k -f flv rtmp://127.0.0.1:1935/live/livestream

pause
