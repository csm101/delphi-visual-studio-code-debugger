@echo off
rem Stand-in for the claude CLI in scripts\smoke_test_setup.bat. Keeps a
rem registry of one file per server name in %SMOKE_FAKES%, holding the
rem registered command, answers `mcp get` the way Claude Code prints it, and
rem logs every call to %SMOKE_FAKES%\claude.log.
setlocal
echo %*>>"%SMOKE_FAKES%\claude.log"
if /i not "%~1"=="mcp" exit /b 0
if /i "%~2"=="get" goto get
if /i "%~2"=="remove" goto remove
if /i "%~2"=="add" goto add
exit /b 0

:get
if not exist "%SMOKE_FAKES%\%~3.reg" (
  echo No MCP server named "%~3".
  exit /b 1
)
set /p REGISTERED=<"%SMOKE_FAKES%\%~3.reg"
echo %~3:
echo   Scope: User config (available in all your projects)
echo   Type: stdio
echo   Command: %REGISTERED%
exit /b 0

:remove
if exist "%SMOKE_FAKES%\%~3.reg" del "%SMOKE_FAKES%\%~3.reg"
exit /b 0

:add
rem claude mcp add <name> -s user -- <command>: the command is the last argument.
set "LAST="
for %%A in (%*) do set "LAST=%%~A"
>"%SMOKE_FAKES%\%~3.reg" echo %LAST%
exit /b 0
