@echo off
chcp 65001 >nul
title Unity CI Build - Agent
cd /d "%~dp0"
echo Agent dang chay. Dong cua so nay la dung agent.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0runner.ps1" -Watch
echo.
pause
