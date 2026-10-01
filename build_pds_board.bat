@echo off
setlocal
cd /d "%~dp0"
python tools/build_pds_board.py %*
exit /b %errorlevel%
