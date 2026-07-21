@echo off
setlocal

set EXT_NAME=local.delphi-win64-debug
set SOURCE_DIR=%~dp0%EXT_NAME%
set TARGET_DIR=%USERPROFILE%\.vscode\extensions\%EXT_NAME%

if not exist "%SOURCE_DIR%\package.json" (
  echo ERROR: source extension folder not found:
  echo   %SOURCE_DIR%
  exit /b 1
)
if not exist "%SOURCE_DIR%\VisualStudioCodeDelphiDebugger.exe" (
  echo ERROR: VisualStudioCodeDelphiDebugger.exe not present in source folder.
  echo Run update-install.bat at the repository root first to build and stage it.
  exit /b 1
)

if exist "%TARGET_DIR%" (
  echo Removing previous installation at %TARGET_DIR% ...
  rmdir /s /q "%TARGET_DIR%"
  if errorlevel 1 (
    echo ERROR: could not remove %TARGET_DIR%.
    exit /b 1
  )
)

echo Installing extension to %TARGET_DIR% ...
xcopy /E /I /Y "%SOURCE_DIR%" "%TARGET_DIR%" >nul
if errorlevel 1 (
  echo ERROR: copy failed.
  exit /b 1
)

echo.
echo Installed: %TARGET_DIR%
echo Reload VS Code to pick up the extension.
exit /b 0
