@echo off
setlocal
python tools/build_axi_control_board_images.py %*
exit /b %errorlevel%
