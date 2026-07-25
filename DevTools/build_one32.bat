@echo off
rem Build a single DevTools probe as a 32-bit binary.
rem
rem build_all.bat compiles every *.dpr here with dcc64, which is right for the
rem tools that drive the adapter (itself 64-bit). A few probes exist precisely
rem to measure what the 32-bit compiler emits and must therefore be built with
rem dcc32 into a Win32\Debug sibling.
rem
rem Usage: build_one32.bat <Probe.dpr>

cd /d %~dp0

if "%~1"=="" (
  echo Usage: build_one32.bat ^<Probe.dpr^>
  exit /b 1
)

call rsvars.bat
if errorlevel 1 exit /b 1

if not exist ".\Win32\Debug" mkdir ".\Win32\Debug"

dcc32 "%~1" -E.\Win32\Debug -NU.\Win32\Debug -$O- -V -VN -VR -DDEBUG
exit /b %errorlevel%
