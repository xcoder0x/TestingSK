@echo off
title USB-JOHN-LLM - Stop
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Windows\usb-john-llm.ps1" -Action stop
timeout /t 2 >nul
