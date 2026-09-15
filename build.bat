@echo off
chcp 65001 >nul
title Unity CI Build
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ci.ps1" build %*
echo.
pause
