@echo off
rem Builds the ExcNestFixture debuggee for BOTH bitnesses, with full debug info.
rem
rem The fixture lives in DevTools\Fixtures\ rather than DevTools\ so that
rem build_all.bat's *.dpr auto-discovery does not pick it up: it is a debuggee,
rem not a tool, and it must be compiled with -$O- -V -VN -VR -GD so that a
rem handler address discovered by ExcHandlerProbe can be mapped back to a
rem source line.
rem
rem   build_exc_fixture.bat            builds Win64 + Win32
rem
rem Outputs:
rem   DevTools\Fixtures\Win64\Debug\ExcNestFixture.exe (+ .map .rsm)
rem   DevTools\Fixtures\Win32\Debug\ExcNestFixture.exe (+ .map .rsm)

cd /d %~dp0Fixtures
call rsvars.bat

if not exist ".\Win64\Debug" mkdir ".\Win64\Debug"
if not exist ".\Win32\Debug" mkdir ".\Win32\Debug"

set DBGFLAGS=-$O- -V -VN -VR -GD -DDEBUG -NSSystem;Winapi;System.Win

echo === ExcNestFixture (Win64) ===
dcc64 ExcNestFixture.dpr %DBGFLAGS% -E.\Win64\Debug -NU.\Win64\Debug 2>&1
if errorlevel 1 (
  echo FAILED: ExcNestFixture Win64
  exit /b 1
)

echo === ExcNestFixture (Win32) ===
dcc32 ExcNestFixture.dpr %DBGFLAGS% -E.\Win32\Debug -NU.\Win32\Debug 2>&1
if errorlevel 1 (
  echo FAILED: ExcNestFixture Win32
  exit /b 1
)

echo OK: Fixtures\Win64\Debug\ExcNestFixture.exe and Fixtures\Win32\Debug\ExcNestFixture.exe
exit /b 0
