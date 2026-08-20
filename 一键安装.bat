@echo off
chcp 65001 >nul 2>&1
cd /d "%~dp0"

echo.
echo  =============================================
echo    Firefox UC 脚本一键安装工具
echo  =============================================
echo.
echo  即将以管理员权限运行安装脚本...
echo  如出现 UAC 弹窗，请点击「是」允许。
echo.

:: 以管理员权限运行 PowerShell 脚本
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0install.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [错误] 安装过程中出现问题，请检查上方输出。
    echo.
)

pause
