@echo off
setlocal

set REPO_ROOT=%~dp0
set EXT_DIR=%REPO_ROOT%install\local.delphi-win64-debug
set BUILT_EXE=%REPO_ROOT%VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe

echo === Building VisualStudioCodeDelphiDebugger ===
call "%REPO_ROOT%build_dap.bat"
if errorlevel 1 (
  echo ERROR: build_dap.bat failed.
  exit /b 1
)

if not exist "%BUILT_EXE%" (
  echo ERROR: build succeeded but %BUILT_EXE% is missing.
  exit /b 1
)

if not exist "%EXT_DIR%" (
  echo ERROR: install folder %EXT_DIR% is missing. Re-run from a clean checkout.
  exit /b 1
)

echo.
echo === Copying VisualStudioCodeDelphiDebugger.exe into install\ ===
copy /Y "%BUILT_EXE%" "%EXT_DIR%\VisualStudioCodeDelphiDebugger.exe" >nul
if errorlevel 1 (
  echo ERROR: copy failed.
  exit /b 1
)

for %%F in ("%EXT_DIR%\VisualStudioCodeDelphiDebugger.exe") do set FSIZE=%%~zF
echo.
echo Installed to: %EXT_DIR%\VisualStudioCodeDelphiDebugger.exe
echo Size:         %FSIZE% bytes
echo Done.
exit /b 0
