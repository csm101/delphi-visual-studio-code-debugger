@echo off
call rsvars.bat
call "%~dp0setpaths.bat" jcl
if errorlevel 1 exit /b 1
pushd "%~dp0..\VisualStudioCodeDelphiDebugger"
if not exist Win64\Debug md Win64\Debug
dcc64 %JCL_FLAGS% VisualStudioCodeDelphiDebugger.dpr
set RESULT=%ERRORLEVEL%
popd
exit /b %RESULT%
