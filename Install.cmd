@echo off
rem Installs HP Quick Modes. Double-click this file; Windows will ask for administrator rights.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-HPQuickModes.ps1" -Pause
