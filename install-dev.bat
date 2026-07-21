@echo off
echo === Building adapter (build_dap.bat) ===
call "%~dp0build_dap.bat"
if errorlevel 1 (
  echo ERROR: adapter build failed. If a debug session is running, stop it ^(Shift+F5^) and retry.
  exit /b 1
)

REM Strip the trailing backslash from %~dp0 before passing it to PowerShell:
REM "%~dp0" expands to "...\" and the closing \" escapes the quote, so the
REM argument arrives with a stray double-quote embedded in the path.
set "REPO_ROOT=%~dp0"
set "REPO_ROOT=%REPO_ROOT:~0,-1%"

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
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-mcp.ps1" "%~dp0MCPDebugger\Win64\Debug\DelphiDebuggerMcp.exe"
exit /b %ERRORLEVEL%
