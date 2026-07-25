@echo off
rem Runs Wow64StackProbe and tees the output to a log file so partial progress
rem is visible while the probe is still running.
rem   run_wow64probe.bat <logfile> <exe> [-rva <hex>] [-maxstops <n>]
cd /d %~dp0
set LOG=%1
shift
Win64\Debug\Wow64StackProbe.exe %1 %2 %3 %4 %5 > "%LOG%" 2>&1
exit /b %errorlevel%
