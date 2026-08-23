@echo off
call rsvars.bat
call "%~dp0setpaths.bat" jcl
if errorlevel 1 exit /b 1

rem TestPlugin.dll is emitted into the SAMPLE's output directory, not its own
rem (-E..\Win64\Debug in TestPlugin.cfg): Debugme loads it with a bare
rem LoadLibrary, so it has to sit next to Debugme.exe. That directory therefore
rem has to exist before the plugin is built, not after.
if not exist "%~dp0..\samples\Debugme\Win64\Debug" md "%~dp0..\samples\Debugme\Win64\Debug"

echo --- Building TestPlugin ---
pushd "%~dp0..\samples\Debugme\TestPlugin"
dcc64 TestPlugin.dpr
if errorlevel 1 ( echo TestPlugin build failed. & popd & exit /b 1 )
popd

echo --- Building Debugme ---
pushd "%~dp0..\samples\Debugme"
dcc64 Debugme.dpr
if errorlevel 1 ( echo Build failed. & popd & exit /b 1 )
popd

echo --- Building VisualStudioCodeDelphiDebugger ---
pushd "%~dp0..\VisualStudioCodeDelphiDebugger"
if not exist Win64\Debug md Win64\Debug
dcc64 %JCL_FLAGS% VisualStudioCodeDelphiDebugger.dpr
if errorlevel 1 ( echo VisualStudioCodeDelphiDebugger build failed. & popd & exit /b 1 )
popd

echo Done.
