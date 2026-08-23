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
rem MAP-ONLY target: a detailed MAP (-GD) with publics and line numbers, and NO
rem embedded debug info (no -V, no -VR/-VN). That is the realistic release-build
rem shape, and the only one where the debugger has an ADDRESS for a global but no
rem TYPE -- which is where a fixed-width read folds the neighbouring variables
rem into the value. Built for both bitnesses because the defect is not
rem architecture specific.
dcc64 -$O- -GD -E.\Win64\Debug -NU.\Win64\Debug MapOnlyGlobals.dpr 2>&1
set MAPONLY64_ERR=%errorlevel%
if not exist Win32\Debug md Win32\Debug
dcc32 -$O- -GD -E.\Win32\Debug -NU.\Win32\Debug MapOnlyGlobals.dpr 2>&1
set MAPONLY32_ERR=%errorlevel%
rem Nested-enum fixture: embedded TD32 (-V) so the tests can read how the
rem compiler records a class-nested type versus a unit-level or routine-local
rem one. Separate target on purpose -- adding declarations to TestTarget shifts
rem the RSM per-unit import indices and has broken unrelated tests before.
dcc64 -$O- -V -VN -E.\Win64\Debug -NU.\Win64\Debug NestedEnumSample.dpr 2>&1
set NESTED64_ERR=%errorlevel%
dcc32 -$O- -V -VN -E.\Win32\Debug -NU.\Win32\Debug NestedEnumSample.dpr 2>&1
set NESTED32_ERR=%errorlevel%
rem No-source-stop fixture: faults inside the RTL (-rtl) or inside kernel32 (-os)
rem so a stop can be observed where the top frame has no source to open. Used to
rem settle, by measurement rather than assumption, whether VS Code opens the
rem Disassembly View by itself and whether our placeholder source suppresses it
rem (see docs/KNOWN_UNKNOWNS.md). Separate target for the usual reason: adding
rem scenarios to TestTarget shifts RSM import indices and marker ordering.
dcc64 -$O- -V -VN -E.\Win64\Debug -NU.\Win64\Debug NoSourceStop.dpr 2>&1
set NOSRC64_ERR=%errorlevel%
dcc32 -$O- -V -VN -E.\Win32\Debug -NU.\Win32\Debug NoSourceStop.dpr 2>&1
set NOSRC32_ERR=%errorlevel%
rem Instruction-stepping fixture: a multi-instruction line, a plain call, a
rem recursive call, a `rep movsb` over 64 KB and a watched write inside a call
rem (docs/ASSEMBLY_LEVEL_DEBUGGING.md increment 1). Full debug info (-V -VN -VR -GD)
rem because the tests place source breakpoints in it and read stop locations.
rem Both bitnesses: instruction stepping is where x86 and x64 differ most.
rem Separate target for the usual reason -- adding scenarios to TestTarget
rem shifts RSM import indices and marker ordering.
dcc64 -$O- -V -VN -VR -GD -E.\Win64\Debug -NU.\Win64\Debug InstructionStepSample.dpr 2>&1
set INSTR64_ERR=%errorlevel%
dcc32 -$O- -V -VN -VR -GD -E.\Win32\Debug -NU.\Win32\Debug InstructionStepSample.dpr 2>&1
set INSTR32_ERR=%errorlevel%
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
rem Exception-step debuggee, both bitnesses. It lives in DevTools\Fixtures (see
rem build_and_run.bat) and is built by its own script because it needs full
rem debug info; built here too so `build_target.bat` alone leaves every test
rem debuggee present.
call "%~dp0..\DevTools\build_exc_fixture.bat"
set EXCFIX_ERR=%errorlevel%
if not "%TT_ERR%"=="0" exit /b %TT_ERR%
if not "%EXCFIX_ERR%"=="0" exit /b %EXCFIX_ERR%
if not "%DLL_ERR%"=="0" exit /b %DLL_ERR%
if not "%EXE_ERR%"=="0" exit /b %EXE_ERR%
if not "%TDS_ERR%"=="0" exit /b %TDS_ERR%
if not "%MAPONLY64_ERR%"=="0" exit /b %MAPONLY64_ERR%
if not "%MAPONLY32_ERR%"=="0" exit /b %MAPONLY32_ERR%
if not "%NESTED64_ERR%"=="0" exit /b %NESTED64_ERR%
if not "%NESTED32_ERR%"=="0" exit /b %NESTED32_ERR%
if not "%NOSRC64_ERR%"=="0" exit /b %NOSRC64_ERR%
if not "%NOSRC32_ERR%"=="0" exit /b %NOSRC32_ERR%
if not "%INSTR64_ERR%"=="0" exit /b %INSTR64_ERR%
if not "%INSTR32_ERR%"=="0" exit /b %INSTR32_ERR%
exit /b %TT32_ERR%
