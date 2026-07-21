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
exit /b 0
