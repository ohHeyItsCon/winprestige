@echo off
rem Starts WinPrestige. Windows asks for administrator rights, which installing apps needs.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0WinPrestige.ps1" -HideConsole %*
