@echo off
setlocal

rem scripts\ is one level below the repository root; keep the trailing
rem backslash, every use below concatenates a path straight onto it.
for %%I in ("%~dp0..") do set "REPO_ROOT=%%~fI\"
set EXT_DIR=%REPO_ROOT%install\mca-software.delphi-debugger
set BUILT_EXE=%REPO_ROOT%VisualStudioCodeDelphiDebugger\Win64\Debug\VisualStudioCodeDelphiDebugger.exe

echo === Building VisualStudioCodeDelphiDebugger ===
call "%~dp0build_dap.bat"
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

rem Optional disassembly backend (docs/DISASSEMBLY_PLAN.md increment 7). Missing is
rem NOT fatal here: the adapter loads Zydis.dll dynamically and degrades
rem disassemble/instructionPointerReference to UNAVAILABLE without it, so a
rem repo without ThirdParty\Zydis\bin\x64\Zydis.dll still stages a working
rem extension -- just without that one optional feature.
set ZYDIS_DLL=%REPO_ROOT%ThirdParty\Zydis\bin\x64\Zydis.dll
if exist "%ZYDIS_DLL%" (
  echo === Copying Zydis.dll ^(disassembly backend^) into install\ ===
  copy /Y "%ZYDIS_DLL%" "%EXT_DIR%\Zydis.dll" >nul
  copy /Y "%REPO_ROOT%ThirdParty\Zydis\LICENSE" "%EXT_DIR%\Zydis-LICENSE.txt" >nul
) else (
  echo NOTE: %ZYDIS_DLL% not found -- disassembly will report UNAVAILABLE in this staged extension.
)

rem The MCP server ships inside the extension too (docs/MCP_SERVER.md, "one
rem release, three channels"): the VSIX registers it with the editor's own MCP
rem registry and keeps a stable per-user copy for agents outside the editor.
echo.
echo === Building MCP server (build_mcp.bat) ===
call "%~dp0build_mcp.bat"
if errorlevel 1 (
  echo ERROR: build_mcp.bat failed.
  exit /b 1
)
copy /Y "%REPO_ROOT%MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe" "%EXT_DIR%\DelphiDebuggerMcp.exe" >nul
if errorlevel 1 (
  echo ERROR: could not copy DelphiDebuggerMcp.exe into install\.
  exit /b 1
)

rem The licence text must be inside the package (vsce refuses to package
rem without one); the repository root is the single source of it.
copy /Y "%REPO_ROOT%LICENSE" "%EXT_DIR%\LICENSE" >nul

rem The MCP server ships inside the extension too (docs/MCP_SERVER.md, "one
rem release, three channels"): the VSIX registers it with the editor's own MCP
rem registry and keeps a stable per-user copy for agents outside the editor.
echo.
echo === Building MCP server (build_mcp.bat) ===
call "%~dp0build_mcp.bat"
if errorlevel 1 (
  echo ERROR: build_mcp.bat failed.
  exit /b 1
)
copy /Y "%REPO_ROOT%MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe" "%EXT_DIR%\DelphiDebuggerMcp.exe" >nul
if errorlevel 1 (
  echo ERROR: could not copy DelphiDebuggerMcp.exe into install\.
  exit /b 1
)

rem The licence text must be inside the package (vsce refuses to package
rem without one); the repository root is the single source of it.
copy /Y "%REPO_ROOT%LICENSE" "%EXT_DIR%\LICENSE" >nul

for %%F in ("%EXT_DIR%\VisualStudioCodeDelphiDebugger.exe") do set FSIZE=%%~zF
echo.
echo Installed to: %EXT_DIR%\VisualStudioCodeDelphiDebugger.exe
echo Size:         %FSIZE% bytes
echo Done.
exit /b 0
