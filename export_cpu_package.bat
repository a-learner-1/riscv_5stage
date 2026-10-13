@echo off
setlocal
chcp 65001 >nul
pushd "%~dp0"
if errorlevel 1 exit /b 2
python -B tools\export_cpu_package.py %*
set CPU_HANDOFF_RESULT=%ERRORLEVEL%
popd
if "%~1"=="" pause
exit /b %CPU_HANDOFF_RESULT%
