@echo off
cd /d %~dp0
call rsvars.bat
if not exist install\__dcu md install\__dcu
dcc64 install\Install.dpr -E.\install -NU.\install\__dcu
if errorlevel 1 (
  echo ERROR: installer build failed.
  exit /b 1
)
echo Built install\Install.exe
exit /b 0
