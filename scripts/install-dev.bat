@echo off
echo === Building adapter (build_dap.bat) ===
call "%~dp0build_dap.bat"
if errorlevel 1 (
  echo ERROR: adapter build failed. If a debug session is running, stop it ^(Shift+F5^) and retry.
  exit /b 1
)

REM The repository root is one level above scripts\, with NO trailing
REM backslash: "%~dp0" ends in one, and the closing \" would then escape the
REM quote and hand PowerShell a path with a stray double-quote inside it.
for %%I in ("%~dp0..") do set "REPO_ROOT=%%~fI"

echo === Pointing installed extension(s) at the build output ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-dev.ps1" "%REPO_ROOT%"
if errorlevel 1 exit /b %ERRORLEVEL%

echo.
echo === Building MCP server (build_mcp.bat) ===
call "%~dp0build_mcp.bat"
if errorlevel 1 (
  echo ERROR: MCP server build failed.
  exit /b 1
)

echo === Registering MCP server with Claude Code + VS Code (build output) ===
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-mcp.ps1" "%REPO_ROOT%\MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe"
exit /b %ERRORLEVEL%
