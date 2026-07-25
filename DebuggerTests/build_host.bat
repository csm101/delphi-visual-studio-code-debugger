@echo off
cd /d %~dp0
call rsvars.bat
if not exist TestHost\Win64\Debug md TestHost\Win64\Debug

pushd TestHost
rem TestSubject.bpl contains the SAME subject units as TestTarget.exe (compiled
rem from ..\TestTarget\*.pas via the .dpk). TestTargetCore.pas must exist first
rem (created when TestTarget.dpr is split). Build the package, then the thin host.
dcc64 TestSubject.dpk 2>&1
if errorlevel 1 ( popd & echo FAILED: TestSubject.bpl & exit /b 1 )
dcc64 TestHost.dpr 2>&1
if errorlevel 1 ( popd & echo FAILED: TestHost.exe & exit /b 1 )
popd

rem LoadPackage / LoadLibrary search the host EXE's directory first, so the BPLs
rem the subject code loads at runtime (TestPackage*, and the no-debug DLL) plus
rem TestSubject.bpl itself must sit next to TestHost.exe.
copy /Y TestHost\Win64\Debug\TestSubject.bpl  TestHost\Win64\Debug\ >nul 2>&1
copy /Y TestPackage\Win64\Debug\TestPackage.bpl   TestHost\Win64\Debug\ >nul
copy /Y TestPackage2\Win64\Debug\TestPackage2.bpl TestHost\Win64\Debug\ >nul
copy /Y TestTarget\Win64\Debug\NoDebugLib.dll     TestHost\Win64\Debug\ >nul

rem --- Win32 host + package, for the 32-bit multi-BPL tests. -----------------
rem This is the project's core use case -- an application split across runtime
rem packages -- and it is the shape where debugger bugs have historically
rem surfaced, so it needs to exist on both bitnesses rather than only x64.
if not exist TestHost\Win32\Debug md TestHost\Win32\Debug
pushd TestHost
dcc32 -E.\Win32\Debug -NU.\Win32\Debug -LE.\Win32\Debug -LN.\Win32\Debug TestSubject.dpk 2>&1
if errorlevel 1 ( popd & echo FAILED: TestSubject.bpl ^(Win32^) & exit /b 1 )
dcc32 -E.\Win32\Debug -NU.\Win32\Debug -LE.\Win32\Debug -LN.\Win32\Debug TestHost.dpr 2>&1
if errorlevel 1 ( popd & echo FAILED: TestHost.exe ^(Win32^) & exit /b 1 )
popd
copy /Y TestPackage\Win32\Debug\TestPackage.bpl   TestHost\Win32\Debug\ >nul
copy /Y TestPackage2\Win32\Debug\TestPackage2.bpl TestHost\Win32\Debug\ >nul
exit /b 0
