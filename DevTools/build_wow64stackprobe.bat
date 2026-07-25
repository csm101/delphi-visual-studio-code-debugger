@echo off
rem Builds only Wow64StackProbe (64-bit), without touching the other tools.
cd /d %~dp0
call rsvars.bat
if not exist Win64\Debug md Win64\Debug
rem 64-bit only by construction: the probe IS the 64-bit debugger side, and the
rem native branch reads TContext.Rip/Rbp/Rsp, which do not exist under dcc32.
echo === dcc64 Wow64StackProbe ===
dcc64 Wow64StackProbe.dpr -E.\Win64\Debug -NU.\Win64\Debug -NSSystem;Winapi;System.Win 2>&1
exit /b %errorlevel%
