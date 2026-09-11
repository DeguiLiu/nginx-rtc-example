@echo off
chcp 65001 >nul

rem Prefer a bundled tools\ffmpeg.exe, otherwise take ffmpeg from PATH.
rem This package does not ship one: ffmpeg's licence and size are its own, and
rem the deploy config is what this package is for.
set "FF=%~dp0tools\ffmpeg.exe"
if not exist "%FF%" set "FF="
if not defined FF for %%I in (ffmpeg.exe) do if not defined FF set "FF=%%~$PATH:I"
if not defined FF (
    echo [ERROR] 找不到 ffmpeg。
    echo         把任意 Windows 版 ffmpeg.exe 放到 "%~dp0tools\" 下，
    echo         或安装 ffmpeg 并把它加进 PATH，然后重新双击本文件。
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
