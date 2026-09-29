@echo off
title USB-JOHN-LLM (Hostdel Packer) - Reseller preparation (internet required)
color 0E
cd /d "%~dp0.."
echo.
echo  This step is for YOU, not the customer. It needs internet.
echo  It downloads the AI model(s), pre-loads them, and then removes
echo  this folder so the customer gets a fully offline product.
echo.
pause
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-usb.ps1"
