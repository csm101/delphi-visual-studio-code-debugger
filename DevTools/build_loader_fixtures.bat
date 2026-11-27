@echo off
rem Builds the fixtures of LoaderTimingProbe for BOTH bitnesses, with TD32 debug
rem info in every image (-V), so the probe can find line records in each module.
rem
rem They live in DevTools\Fixtures\LoaderTiming\ so that build_all.bat's *.dpr
rem auto-discovery does not pick them up: they are debuggees, not tools.
rem
rem   build_loader_fixtures.bat          builds Win64 + Win32
rem
rem Outputs, in DevTools\Fixtures\LoaderTiming\Win64\Debug and ...\Win32\Debug:
rem   LtHost.exe         host; requires rtl + LtPkgStatic, imports LtDllStatic.dll
rem   LtPkgStatic.bpl    runtime package the host requires statically
rem   LtPkgDynamic.bpl   runtime package the host loads with LoadPackage
rem   LtDllStatic.dll    plain DLL the host imports statically
rem   LtDllDynamic.dll   plain DLL the host loads with LoadLibrary
rem   LtFixA.dll LtFixB.dll   same fixed image base, no dynamic base
rem   LtDynA.dll LtDynB.dll   same preferred image base, dynamic base
rem
rem LtHost.exe needs rtl290.bpl at run time: %BDS%\bin64 (Win64) or %BDS%\bin
rem (Win32) must be on the PATH, or be given to the probe with -path.

cd /d %~dp0Fixtures\LoaderTiming
call rsvars.bat

call :build dcc64 Win64
if errorlevel 1 exit /b 1
call :build dcc32 Win32
if errorlevel 1 exit /b 1

echo OK: Fixtures\LoaderTiming\Win64\Debug and Fixtures\LoaderTiming\Win32\Debug
exit /b 0

:build
set OUT=.\%2\Debug
if not exist "%OUT%" mkdir "%OUT%"
set FLAGS=-B -Q -$O- -$D+ -$L+ -V -GD -DDEBUG -NSSystem;Winapi;System.Win -E%OUT% -NU%OUT% -LE%OUT% -LN%OUT% -U%OUT%

for %%P in (LtPkgStatic LtPkgDynamic) do (
  echo === %%P.bpl ^(%2^) ===
  %1 %%P.dpk %FLAGS% 2>&1
  if errorlevel 1 goto failed
)
for %%D in (LtFixA LtFixB LtDynA LtDynB LtDllStatic LtDllDynamic) do (
  echo === %%D.dll ^(%2^) ===
  %1 %%D.dpr %FLAGS% 2>&1
  if errorlevel 1 goto failed
)
echo === LtHost.exe ^(%2^) ===
%1 LtHost.dpr %FLAGS% -LUrtl;LtPkgStatic 2>&1
if errorlevel 1 goto failed
exit /b 0

:failed
echo FAILED: LoaderTiming fixtures, %2
exit /b 1
