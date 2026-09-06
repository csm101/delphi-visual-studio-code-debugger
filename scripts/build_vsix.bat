@echo off
rem Packages the staged extension folder into dist\mca-software.delphi-debugger-<version>.vsix
rem with vsce, the Marketplace's own packaging tool, so the file uploaded to the
rem Marketplace and the one inside the setup zip are the same artefact.
rem
rem Needs Node on PATH (npx fetches @vscode/vsce on first use). No publisher
rem token: nothing here publishes anything. The staged folder must already hold
rem the adapter and the MCP server (scripts\update-install.bat does that).
setlocal
for %%I in ("%~dp0..") do set "REPO=%%~fI"
set EXT_DIR=%REPO%\install\mca-software.delphi-debugger
set DIST=%REPO%\dist
if not exist "%DIST%" mkdir "%DIST%"

where npx >nul 2>&1
if errorlevel 1 (
  echo ERROR: npx not found. Install Node.js to package the extension with vsce.
  exit /b 1
)
if not exist "%EXT_DIR%\VisualStudioCodeDelphiDebugger.exe" (
  echo ERROR: %EXT_DIR%\VisualStudioCodeDelphiDebugger.exe is missing. Run scripts\update-install.bat first.
  exit /b 1
)
if not exist "%EXT_DIR%\DelphiDebuggerMcp.exe" (
  echo ERROR: %EXT_DIR%\DelphiDebuggerMcp.exe is missing. Run scripts\update-install.bat first.
  exit /b 1
)

set VER=
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "(Get-Content -Raw '%EXT_DIR%\package.json' | ConvertFrom-Json).version"`) do set VER=%%V
if "%VER%"=="" (
  echo ERROR: could not read the version from %EXT_DIR%\package.json.
  exit /b 1
)
set VSIX=%DIST%\mca-software.delphi-debugger-%VER%.vsix
if exist "%VSIX%" del /q "%VSIX%"

rem --no-dependencies: the extension has no npm dependencies and no node_modules,
rem and without the flag vsce runs `npm list` and fails on the absent lockfile.
rem --allow-star-activation is NOT needed (the manifest lists its events).
pushd "%EXT_DIR%"
call npx --yes @vscode/vsce package --no-dependencies --out "%VSIX%"
set RESULT=%ERRORLEVEL%
popd
if not "%RESULT%"=="0" (
  echo ERROR: vsce package failed with %RESULT%.
  exit /b %RESULT%
)
if not exist "%VSIX%" (
  echo ERROR: vsce reported success but %VSIX% does not exist.
  exit /b 1
)
echo Built: %VSIX%
exit /b 0
