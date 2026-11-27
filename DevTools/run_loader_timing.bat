@echo off
rem Runs every LoaderTimingProbe measurement against its fixtures, both bitnesses,
rem and leaves one text file per run in %TEMP%\LoaderTimingProbe.
rem
rem   run_loader_timing.bat [ProbeDir]
rem
rem [ProbeDir]  directory of LoaderTimingProbe.exe, relative to DevTools
rem             (default Win64\Debug).
rem
rem Build first: build_one.bat LoaderTimingProbe, build_loader_fixtures.bat.
rem rsvars.bat supplies %BDS%: LtHost.exe is built with runtime packages and needs
rem rtl290.bpl from %BDS%\bin64 (Win64) or %BDS%\bin (Win32).

cd /d %~dp0
call rsvars.bat

set PROBEDIR=%~1
if "%PROBEDIR%"=="" set PROBEDIR=Win64\Debug
set PROBE=%PROBEDIR%\LoaderTimingProbe.exe
if not exist "%PROBE%" (
  echo %PROBE% not found: build_one.bat LoaderTimingProbe
  exit /b 2
)
set OUT=%TEMP%\LoaderTimingProbe
if not exist "%OUT%" mkdir "%OUT%"

call :bitness Win64 "%BDS%\bin64"
call :bitness Win32 "%BDS%\bin"
echo.
echo Reports in %OUT%
exit /b 0

:bitness
set FIX=Fixtures\LoaderTiming\%1\Debug
set HOST=%FIX%\LtHost.exe
if not exist "%HOST%" (
  echo %HOST% not found: build_loader_fixtures.bat
  exit /b 2
)
set RUN="%PROBE%" -run -path %2
echo === %1 ===

rem The PE header flags of every fixture, as the files hold them.
"%PROBE%" -pe %FIX%\LtFixA.dll %FIX%\LtFixB.dll %FIX%\LtDynA.dll %FIX%\LtDynB.dll %FIX%\LtDllStatic.dll %FIX%\LtDllDynamic.dll %FIX%\LtPkgStatic.bpl %FIX%\LtPkgDynamic.bpl %FIX%\LtHost.exe > "%OUT%\pe_%1.txt" 2>&1
call :done pe_%1

rem Q1: are relocations applied before LOAD_DLL_DEBUG_EVENT. Two DLLs with the
rem same image base, without and with a dynamic base.
%RUN% -entries own -reloc LtFixA.dll -reloc LtFixB.dll %HOST% -dll LtFixA.dll -dll LtFixB.dll > "%OUT%\q1_fixed_%1.txt" 2>&1
call :done q1_fixed_%1
%RUN% -entries own -reloc LtDynA.dll -reloc LtDynB.dll %HOST% -dll LtDynA.dll -dll LtDynB.dll > "%OUT%\q1_dynamic_%1.txt" 2>&1
call :done q1_dynamic_%1
rem The executable itself, watched from CREATE_PROCESS_DEBUG_EVENT.
%RUN% -entries own -reloc LtHost.exe %HOST% > "%OUT%\q1_exe_%1.txt" 2>&1
call :done q1_exe_%1
rem The same load with nothing planted: the event order is the loader's own.
%RUN% -entries none %HOST% -dll LtFixA.dll -dll LtFixB.dll > "%OUT%\q1_fixed_unplanted_%1.txt" 2>&1
call :done q1_fixed_unplanted_%1

rem Q2: a $CC planted at the load event on a relocated instruction and on every
rem line record; then the negative experiment with a five-byte jump.
%RUN% -baseline -entries own -reloc LtFixB.dll -plantsite -lines LtFixB.dll %HOST% -dll LtFixA.dll -dll LtFixB.dll > "%OUT%\q2_int3_%1.txt" 2>&1
call :done q2_int3_%1
%RUN% -baseline -entries own -reloc LtFixB.dll -jmppatch %HOST% -dll LtFixA.dll -dll LtFixB.dll > "%OUT%\q2_jmp_%1.txt" 2>&1
call :done q2_jmp_%1

rem Q3: what has run when. Entry-point one-shots on every module, line one-shots
rem on every fixture module.
%RUN% -entries all -lines LtHost.exe -lines LtPkgStatic.bpl -lines LtDllStatic.dll -lines LtPkgDynamic.bpl -lines LtDllDynamic.dll %HOST% -pkg LtPkgDynamic.bpl -dll LtDllDynamic.dll > "%OUT%\q3_order_%1.txt" 2>&1
call :done q3_order_%1
rem Negative control: the same with a $CC on the line records that lie in no
rem routine as well. The target is expected to fault inside LoadPackage.
%RUN% -timeout 10 -entries own -anyrecord -lines LtPkgDynamic.bpl %HOST% -pkg LtPkgDynamic.bpl > "%OUT%\q3_anyrecord_%1.txt" 2>&1
call :done q3_anyrecord_%1

rem Q4: the same host, attached to while it waits.
"%PROBE%" -attach -path %2 %HOST% -wait -pkg LtPkgDynamic.bpl -dll LtDllDynamic.dll > "%OUT%\q4_attach_%1.txt" 2>&1
call :done q4_attach_%1
exit /b 0

:done
echo   %1.txt   probe exit code %errorlevel%
exit /b 0
