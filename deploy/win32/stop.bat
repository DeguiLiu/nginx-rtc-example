@echo off
cd /d "%~dp0"
nginx.exe -s stop
echo [OK] nginx stopped.
pause
