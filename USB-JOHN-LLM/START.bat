@echo off
title USB-JOHN-LLM by Hostdel Packer
color 0B
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows\usb-john-llm.ps1" -Action start
if errorlevel 1 (
  echo.
  echo  USB-JOHN-LLM could not start. See the messages above.
  echo.
  pause
)
