@echo off
rem CadMath 安装与更新工具 —— 双击运行
setlocal
set "CADMATH_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "CADMATH_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%~dp0tools\setup\CadMath-Setup.ps1" (
  echo.
  echo 找不到 tools\setup\CadMath-Setup.ps1。
  echo 请先完整解压发行包，再运行 CadMath-Setup.cmd。
  echo.
  pause
  exit /b 1
)

title CadMath 安装与更新工具
"%CADMATH_PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tools\setup\CadMath-Setup.ps1" %*
set "CADMATH_EXIT=%ERRORLEVEL%"
if not "%CADMATH_EXIT%"=="0" (
  echo.
  echo 工具以退出码 %CADMATH_EXIT% 结束。
  pause
)
exit /b %CADMATH_EXIT%
