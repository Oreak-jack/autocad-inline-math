@echo off
rem CadMath setup launcher. Double click to run.
rem Keep this file ASCII-only with CRLF line endings: cmd.exe mis-parses LF-only batch files.
setlocal
set "CADMATH_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "CADMATH_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%~dp0tools\setup\CadMath-Setup.ps1" goto missing

title CadMath Setup
pushd "%~dp0"
"%CADMATH_PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tools\setup\CadMath-Setup.ps1" %*
set "CADMATH_EXIT=%ERRORLEVEL%"
popd

if not "%CADMATH_EXIT%"=="0" goto failed
if not "%~1"=="" exit /b 0
echo.
echo Done. Press any key to close this window.
pause >nul
exit /b 0

:missing
echo.
echo [CadMath] tools\setup\CadMath-Setup.ps1 not found.
echo Please extract the whole release zip first, then run CadMath-Setup.cmd again.
echo.
pause
exit /b 1

:failed
echo.
echo [CadMath] setup exited with code %CADMATH_EXIT%.
pause
exit /b %CADMATH_EXIT%
