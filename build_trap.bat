@echo off
python tools\build_trap_images.py %*
exit /b %errorlevel%
