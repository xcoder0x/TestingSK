@echo off
title USB-JOHN-LLM - Install
color 0A
cd /d "%~dp0"
echo.
echo  ==================================================
echo    USB-JOHN-LLM  -  One-click offline installer
echo  ==================================================
echo.
echo  Nothing is downloaded. Everything runs from this drive.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows\usb-john-llm.ps1" -Action install
if errorlevel 1 (
  echo.
  echo  Installation reported a problem. See the messages above.
  echo.
  pause
)
