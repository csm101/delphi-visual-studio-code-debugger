@echo off
rem Builds the MCP stdio server exe from MCPDebugger\, resolving the shared engine
rem units from DebuggerCore\. DCUs + exe land in MCPDebugger\Win64\Debug\.
call rsvars.bat
call "%~dp0setpaths.bat" jcl
if errorlevel 1 exit /b 1
pushd "%~dp0MCPDebugger"
if not exist Win64\Debug md Win64\Debug
rem -GD emits a detailed .map so a crash/hang dump of this exe can be symbolicated
rem (needed to name functions in a hang like F14; see MCP_LIVE_FINDINGS_TODO.md).
dcc64 -GD -U..\DebuggerCore %JCL_FLAGS% -E.\Win64\Debug -NU.\Win64\Debug DelphiDebuggerMcp.dpr
set RESULT=%ERRORLEVEL%
popd
exit /b %RESULT%
