@echo off
chcp 65001 >nul
title Unity CI Build - Setup
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 (
  echo [X] Khong tim thay PowerShell. Can Windows 10 tro len.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
echo.
pause
