@echo off
rem Builds the TrampolineFixture debuggee for BOTH bitnesses, with full debug info.
rem
rem It is the fixture of PatchFeasibilityProbe (docs\PROFILER_COVERAGE_PLAN.md,
rem increment 1). Like ExcNestFixture it lives in DevTools\Fixtures\ so that
rem build_all.bat's *.dpr discovery does not pick it up, and it is compiled
rem unoptimised with -V -VN -VR -GD: the probe finds every address it patches
rem from the TD32 line table.
rem
rem   build_trampoline_fixture.bat          builds Win64 + Win32
rem
rem Outputs:
rem   DevTools\Fixtures\Win64\Debug\TrampolineFixture.exe (+ .map .rsm)
rem   DevTools\Fixtures\Win32\Debug\TrampolineFixture.exe (+ .map .rsm)

cd /d %~dp0Fixtures
call rsvars.bat

if not exist ".\Win64\Debug" mkdir ".\Win64\Debug"
if not exist ".\Win32\Debug" mkdir ".\Win32\Debug"

set DBGFLAGS=-$O- -V -VN -VR -GD -DDEBUG -NSSystem;Winapi;System.Win

echo === TrampolineFixture (Win64) ===
dcc64 TrampolineFixture.dpr %DBGFLAGS% -E.\Win64\Debug -NU.\Win64\Debug 2>&1
if errorlevel 1 (
  echo FAILED: TrampolineFixture Win64
  exit /b 1
)

echo === TrampolineFixture (Win32) ===
dcc32 TrampolineFixture.dpr %DBGFLAGS% -E.\Win32\Debug -NU.\Win32\Debug 2>&1
if errorlevel 1 (
  echo FAILED: TrampolineFixture Win32
  exit /b 1
)

echo OK: Fixtures\Win64\Debug\TrampolineFixture.exe and Fixtures\Win32\Debug\TrampolineFixture.exe
exit /b 0
