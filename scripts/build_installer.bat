@echo off
cd /d "%~dp0.."
call rsvars.bat
rem The compiler options live in install\Install.rsp, not on this command line.
rem dcc does not create its unit output folder (F2039), so it is made here.
if not exist install\Win64\Debug md install\Win64\Debug
dcc64 install\Install.dpr @install\Install.rsp
if errorlevel 1 (
  echo ERROR: installer build failed.
  exit /b 1
)
echo Built install\Install.exe
exit /b 0
