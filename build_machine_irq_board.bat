@echo off
setlocal
pushd "%~dp0"
python tools\build_machine_irq_board_images.py %*
set BUILD_RESULT=%ERRORLEVEL%
popd
exit /b %BUILD_RESULT%
