@echo off
setlocal
rem One parse applies the same profile, iterations and toolchain to all targets.
rem Explicit --cache/--btb options are rejected by --compare all.
call "%~dp0build_coremark_axi.bat" --compare all %*
exit /b %ERRORLEVEL%
