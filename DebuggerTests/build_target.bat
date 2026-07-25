@echo off
cd /d %~dp0
call rsvars.bat
if not exist TestTarget\Win64\Debug md TestTarget\Win64\Debug
pushd TestTarget
dcc64 TestTarget.dpr 2>&1
set TT_ERR=%errorlevel%
rem Plain DLL built WITHOUT debug info (no -V/-VR/-VN, debug switches off) so
rem the adapter sees a module it has no symbols for. Output beside TestTarget.exe
rem so a relative LoadLibrary finds it.
dcc64 -$D- -$L- -$Y- -E.\Win64\Debug -NU.\Win64\Debug NoDebugLib.dpr 2>&1
set DLL_ERR=%errorlevel%
rem No-debug EXE (no -V/-VR/-VN): a blind main module for the "no debug info" diagnostic.
dcc64 -$D- -$L- -$Y- -E.\Win64\Debug -NU.\Win64\Debug NoDebugExe.dpr 2>&1
set EXE_ERR=%errorlevel%
rem External-TDS target (-VT): debug info in a standalone .tds, no embedded .debug.
dcc64 -$O- -VT -VN -E.\Win64\Debug -NU.\Win64\Debug TdsSample.dpr 2>&1
set TDS_ERR=%errorlevel%
rem 32-bit build of the SAME sources, for the Win32 target-support tests.
rem TestTarget.cfg hardcodes -E/-NU to Win64\Debug; dcc reads the .cfg first and
rem the command line second, and for -E/-NU the last occurrence wins, so these
rem overrides redirect the output without forking the .cfg -- a forked .cfg is
rem exactly the duplicate that goes stale unnoticed.
if not exist Win32\Debug md Win32\Debug
dcc32 -E.\Win32\Debug -NU.\Win32\Debug TestTarget.dpr 2>&1
set TT32_ERR=%errorlevel%
popd
if not "%TT_ERR%"=="0" exit /b %TT_ERR%
if not "%DLL_ERR%"=="0" exit /b %DLL_ERR%
if not "%EXE_ERR%"=="0" exit /b %EXE_ERR%
if not "%TDS_ERR%"=="0" exit /b %TDS_ERR%
exit /b %TT32_ERR%
