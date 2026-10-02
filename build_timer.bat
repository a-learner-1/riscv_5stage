@echo off
python tools\build_timer_images.py %*
exit /b %errorlevel%
