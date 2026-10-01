@echo off
setlocal
cd /d "%~dp0"
python tools/build_uart_rx_images.py
exit /b %errorlevel%
