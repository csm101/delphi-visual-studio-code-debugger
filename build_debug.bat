@echo off
call rsvars.bat
call "%~dp0setpaths.bat" jcl
if errorlevel 1 exit /b 1

echo --- Building TestPlugin ---
pushd TestPlugin
if not exist Win64\Debug md Win64\Debug
dcc64 TestPlugin.dpr
if errorlevel 1 ( echo TestPlugin build failed. & popd & exit /b 1 )
popd

echo --- Building Debugme ---
if not exist Win64\Debug md Win64\Debug
dcc64 Debugme.dpr
if errorlevel 1 ( echo Build failed. & exit /b 1 )

echo --- Building VisualStudioCodeDelphiDebugger ---
pushd VisualStudioCodeDelphiDebugger
if not exist Win64\Debug md Win64\Debug
dcc64 %JCL_FLAGS% VisualStudioCodeDelphiDebugger.dpr
if errorlevel 1 ( echo VisualStudioCodeDelphiDebugger build failed. & popd & exit /b 1 )
popd

echo Done.
