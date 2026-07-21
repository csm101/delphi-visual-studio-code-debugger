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
exit /b 0
