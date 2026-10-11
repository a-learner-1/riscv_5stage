@echo off
setlocal
chcp 65001 >nul
pushd "%~dp0"
python -B tools\run_regression.py %*
set REGRESSION_RESULT=%ERRORLEVEL%
popd
if "%~1"=="" pause
exit /b %REGRESSION_RESULT%
