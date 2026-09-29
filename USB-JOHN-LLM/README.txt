USB-JOHN-LLM by Hostdel Packer  -  private offline AI on a USB drive
=================================================================

Requirements
  - Windows 10 / 11 / Windows Server 2016 or newer (64-bit)
  - 8 GB RAM minimum (16 GB recommended for the larger models)
  - No internet connection is needed. Nothing is downloaded.

First time on a computer
  1. Plug in the drive and open it in File Explorer.
  2. Double-click  INSTALL.bat
     (If Windows shows "Windows protected your PC", click "More info" then "Run anyway".)
  3. The installer prepares the AI models (a few minutes, once per drive)
     and then opens the chat in your browser at  http://localhost:3333

Every other time
  - Double-click  START.bat   - the chat opens in your browser.
  - Close the black window (or double-click STOP.bat) to shut everything down.

Using it from a phone or another PC on the same Wi-Fi
  - The black window shows a "Network Access" address such as http://192.168.1.15:3333
  - Open that address in the phone's browser.
  - If it does not load, allow port 3333 in Windows Firewall.

Folder layout
  INSTALL.bat / START.bat / STOP.bat     one-click controls
  Windows\                               launcher scripts
  Shared\bin\                            AI engine
  Shared\python\                         portable Python (nothing is installed on the PC)
  Shared\models\                         AI model files
  Shared\chat_data\                      your saved chats (stay on the drive)
  Shared\logs\                           log files, useful if something fails

Troubleshooting
  - "Model file missing": the drive was not prepared completely. Contact Hostdel Packer support.
  - Slow answers: choose the smaller model in the chat's model selector.
  - Port already in use: run STOP.bat, then START.bat again.
