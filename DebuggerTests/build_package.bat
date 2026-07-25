@echo off
cd /d %~dp0
call rsvars.bat
if not exist TestPackage\Win64\Debug md TestPackage\Win64\Debug
if not exist TestPackage2\Win64\Debug md TestPackage2\Win64\Debug
if not exist TestTarget\Win64\Debug md TestTarget\Win64\Debug
pushd TestPackage
dcc64 TestPackage.dpk 2>&1
if errorlevel 1 ( popd & exit /b 1 )
popd
pushd TestPackage2
rem TestPackage2 requires TestPackage (uses-graph test): dcc64 needs the
rem required package's .dcp on the unit search path.
dcc64 -U..\TestPackage\Win64\Debug TestPackage2.dpk 2>&1
if errorlevel 1 ( popd & exit /b 1 )
popd
rem Copy BPLs next to TestTarget.exe — LoadPackage uses Win32 LoadLibrary,
rem which searches the EXE's directory before the package's source dir.
copy /Y TestPackage\Win64\Debug\TestPackage.bpl TestTarget\Win64\Debug\ >nul
copy /Y TestPackage2\Win64\Debug\TestPackage2.bpl TestTarget\Win64\Debug\ >nul

rem --- Win32 build of the same packages, for the 32-bit BPL tests. -----------
rem The .cfg redirects -E/-NU/-LE/-LN to Win64\Debug; dcc lets the command line
rem win, so all four are overridden here rather than forking the config.
if not exist TestPackage\Win32\Debug md TestPackage\Win32\Debug
if not exist TestPackage2\Win32\Debug md TestPackage2\Win32\Debug
if not exist TestTarget\Win32\Debug md TestTarget\Win32\Debug
pushd TestPackage
dcc32 -E.\Win32\Debug -NU.\Win32\Debug -LE.\Win32\Debug -LN.\Win32\Debug TestPackage.dpk 2>&1
if errorlevel 1 ( popd & echo FAILED: TestPackage ^(Win32^) & exit /b 1 )
popd
pushd TestPackage2
dcc32 -U..\TestPackage\Win32\Debug -E.\Win32\Debug -NU.\Win32\Debug -LE.\Win32\Debug -LN.\Win32\Debug TestPackage2.dpk 2>&1
if errorlevel 1 ( popd & echo FAILED: TestPackage2 ^(Win32^) & exit /b 1 )
popd
copy /Y TestPackage\Win32\Debug\TestPackage.bpl TestTarget\Win32\Debug\ >nul
copy /Y TestPackage2\Win32\Debug\TestPackage2.bpl TestTarget\Win32\Debug\ >nul
exit /b 0
