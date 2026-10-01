@echo off
setlocal
cd /d "%~dp0"
python tools/build_board_images.py
exit /b %errorlevel%
