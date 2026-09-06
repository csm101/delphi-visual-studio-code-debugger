@echo off
REM Build a self-contained, distributable setup zip for the Delphi Win64 Debugger.
REM Output: dist\delphi-win64-debugger-setup-v<version>.zip containing:
REM   Setup.exe                     - portable installer (also runs as updater)
REM   mca-software.delphi-debugger\ - the VS Code extension (manifest + adapter + MCP server)
REM   mca-software.delphi-debugger-<version>.vsix - the same, packaged by vsce
REM                                   (Setup.exe installs this one when present)
REM   INSTALL_INSTRUCTIONS.md
REM
REM On a target PC: extract the zip anywhere and run Setup.exe. If the extension is
REM already installed it is updated in place; otherwise it is installed fresh.
setlocal
rem scripts\ is one level below the repository root, so %~dp0 is NOT the root.
rem Sibling scripts stay on %~dp0; anything repository-relative uses %REPO%.
for %%I in ("%~dp0..") do set "REPO=%%~fI"
cd /d "%REPO%"

echo === [1/3] Build adapter and MCP server, stage them into install\mca-software.delphi-debugger ===
call "%~dp0update-install.bat"
if errorlevel 1 (
  echo ERROR: update-install.bat failed.
  exit /b 1
)

rem The VSIX is packaged by vsce, the Marketplace's own tool, so that the zip
rem carries the SAME artefact that is uploaded to the Marketplace. Node is a
rem build-machine requirement only: Setup.exe falls back to packaging the
rem folder itself when no .vsix is next to it.
echo === [1b/3] Package the extension with vsce ===
call "%~dp0build_vsix.bat"
if errorlevel 1 (
  echo WARNING: build_vsix.bat failed; the zip will carry no .vsix and Setup.exe will package the folder itself.
)

echo.
echo === [2/3] Build Setup.exe (install\Install.exe) ===
call "%~dp0build_installer.bat"
if errorlevel 1 (
  echo ERROR: build_installer.bat failed.
  exit /b 1
)

set DIST=%REPO%\dist
set STAGE=%DIST%\delphi-win64-debugger-setup
if exist "%STAGE%" rmdir /s /q "%STAGE%"
mkdir "%STAGE%"

copy /Y "%REPO%\install\Install.exe" "%STAGE%\Setup.exe" >nul
if errorlevel 1 (
  echo ERROR: could not copy Setup.exe.
  exit /b 1
)
xcopy /E /I /Y "%REPO%\install\mca-software.delphi-debugger" "%STAGE%\mca-software.delphi-debugger" >nul
if errorlevel 1 (
  echo ERROR: could not copy extension folder.
  exit /b 1
)
copy /Y "%REPO%\install\INSTALL_INSTRUCTIONS.md" "%STAGE%\INSTALL_INSTRUCTIONS.md" >nul
if exist "%DIST%\mca-software.delphi-debugger-*.vsix" copy /Y "%DIST%\mca-software.delphi-debugger-*.vsix" "%STAGE%\" >nul

rem MCP server exe + its registration script (Setup.exe installs + registers them).
copy /Y "%REPO%\MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe" "%STAGE%\DelphiDebuggerMcp.exe" >nul
if errorlevel 1 (
  echo ERROR: could not copy MCP server exe.
  exit /b 1
)
copy /Y "%~dp0register-mcp.ps1" "%STAGE%\register-mcp.ps1" >nul

rem Disassembly backend (docs/DISASSEMBLY_PLAN.md increment 7), staged next to
rem Setup.exe: Install.exe (renamed Setup.exe) copies it from here alongside
rem the MCP server exe into its per-user install location. Missing is a
rem warning, not a build failure -- the adapter/MCP server still start and
rem work for everything except disassemble/instructionPointerReference, which
rem degrade to UNAVAILABLE without it.
if exist "%REPO%\ThirdParty\Zydis\bin\x64\Zydis.dll" (
  copy /Y "%REPO%\ThirdParty\Zydis\bin\x64\Zydis.dll" "%STAGE%\Zydis.dll" >nul
  copy /Y "%REPO%\ThirdParty\Zydis\LICENSE" "%STAGE%\Zydis-LICENSE.txt" >nul
) else (
  echo WARNING: ThirdParty\Zydis\bin\x64\Zydis.dll not found -- this zip's MCP server will report disassembly UNAVAILABLE.
)

echo.
echo === [3/3] Compress to zip ===
set VER=
for /f "usebackq delims=" %%V in (`powershell -NoProfile -Command "(Get-Content -Raw '%REPO%\install\mca-software.delphi-debugger\package.json' | ConvertFrom-Json).version"`) do set VER=%%V
if "%VER%"=="" set VER=0.0.0
set ZIP=%DIST%\delphi-win64-debugger-setup-v%VER%.zip
if exist "%ZIP%" del /q "%ZIP%"
powershell -NoProfile -Command "Compress-Archive -Path '%STAGE%\*' -DestinationPath '%ZIP%' -Force"
if errorlevel 1 (
  echo ERROR: Compress-Archive failed.
  exit /b 1
)

echo.
echo Built: %ZIP%
exit /b 0
