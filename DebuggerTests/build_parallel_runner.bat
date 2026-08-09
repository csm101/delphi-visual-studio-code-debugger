@echo off
rem Builds the parallel test driver (RunTestsParallel.exe). It only orchestrates
rem RunTests.exe processes, so it needs neither DUnitX nor the debugger core.
cd /d %~dp0
call rsvars.bat
if not exist Win64\Debug md Win64\Debug
dcc64 -E.\Win64\Debug -NU.\Win64\Debug RunTestsParallel.dpr 2>&1
exit /b %errorlevel%
