@echo off
cd /d "%~dp0"
python tools\build_btb_board_images.py %*
if errorlevel 1 exit /b 1
exit /b 0
