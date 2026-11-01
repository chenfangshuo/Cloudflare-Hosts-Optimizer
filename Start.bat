@echo off
setlocal EnableExtensions
chcp 65001 >nul
pushd "%~dp0"

if not exist "%~dp0Menu.ps1" (
    echo.
    echo [错误] 没有找到 Menu.ps1，请先把压缩包完整解压，再运行 Start.bat。
    pause
    exit /b 1
)

call :find_pwsh
if defined PWSH goto :check

echo.
echo 需要 PowerShell 7，但当前系统没有找到。
where winget.exe >nul 2>nul
if errorlevel 1 goto :manual

echo 是否现在用 winget 安装 PowerShell 7？[Y/N]
choice /C YN /N /M "> "
if errorlevel 2 goto :manual

winget install --id Microsoft.PowerShell --source winget --exact --accept-package-agreements --accept-source-agreements --silent --disable-interactivity

call :find_pwsh

:check
if not defined PWSH goto :manual
"%PWSH%" -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 7) { exit 1 }" >nul 2>nul
if errorlevel 1 goto :manual

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Menu.ps1" %*
if errorlevel 1 pause
popd
exit /b 0

:manual
echo.
echo 请手动安装 PowerShell 7，安装完成后关闭此窗口，再重新运行 Start.bat。
echo 下载地址：https://aka.ms/powershell-release?tag=stable
pause
popd
exit /b 1

:find_pwsh
set "PWSH="
for %%P in (pwsh.exe) do if not defined PWSH set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7-preview\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7-preview\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
exit /b 0
