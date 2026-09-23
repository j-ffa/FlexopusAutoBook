@echo off
rem Double-click to open the annual leave calendar in your browser.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0LeaveUI.ps1" %*
if errorlevel 1 pause
