@echo off
chcp 65001 >nul
title Unity CI Build - Agent Bootstrap
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-agent.ps1"
echo.
pause
