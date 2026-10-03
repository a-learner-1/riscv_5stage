@echo off
cd /d "%~dp0"
python tools\build_icache_board_images.py %*
if errorlevel 1 exit /b 1
exit /b 0
