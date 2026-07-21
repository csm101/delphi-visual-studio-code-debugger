@echo off
cd /d %~dp0
call rsvars.bat
call ..\setpaths.bat jcl dunitx
if errorlevel 1 exit /b 1
if not exist Win64\Debug md Win64\Debug
dcc64 -U..\DebuggerCore %JCL_FLAGS% %DUNITX_FLAGS% RunTests.dpr 2>&1
exit /b %errorlevel%
