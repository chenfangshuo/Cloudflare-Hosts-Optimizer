@echo off
setlocal EnableExtensions
chcp 65001 >nul
pushd "%~dp0"

set "PWSH="
for %%P in (pwsh.exe) do if not defined PWSH set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7-preview\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7-preview\pwsh.exe"

if defined PWSH goto :check

echo.
echo PowerShell 7 is required but was not found.
where winget.exe >nul 2>nul
if errorlevel 1 goto :manual

echo Install PowerShell 7 with winget now? [Y/N]
choice /C YN /N /M "> "
if errorlevel 2 goto :manual

winget install --id Microsoft.PowerShell --source winget --exact --accept-package-agreements --accept-source-agreements --silent --disable-interactivity

if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
for %%P in (pwsh.exe) do if not defined PWSH set "PWSH=%%~$PATH:P"

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
echo Please install PowerShell 7 manually, then close this window and run Start.bat again.
echo Download: https://aka.ms/powershell-release?tag=stable
pause
popd
exit /b 1
