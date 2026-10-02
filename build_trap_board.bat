@echo off
python tools\build_trap_board_images.py %*
exit /b %errorlevel%
