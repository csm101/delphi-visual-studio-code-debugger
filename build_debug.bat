@echo off
call rsvars.bat

echo --- Building TestPlugin ---
pushd TestPlugin
dcc64 TestPlugin.dpr
if errorlevel 1 ( echo TestPlugin build failed. & popd & exit /b 1 )
popd

echo --- Building Debugme ---
dcc64 Debugme.dpr
if errorlevel 1 ( echo Build failed. & exit /b 1 )

echo --- Building VisualStudioCodeDelphiDebugger ---
pushd VisualStudioCodeDelphiDebugger
dcc64 VisualStudioCodeDelphiDebugger.dpr
if errorlevel 1 ( echo VisualStudioCodeDelphiDebugger build failed. & popd & exit /b 1 )
popd

echo Done.
