@echo off
REM Runs Setup.exe from a setup-zip layout the way a user would, in a sandbox,
REM and fails unless it does what it is for:
REM
REM   1. install: portable mode, the MCP server installed and registered with
REM      Claude Code on the stable copy;
REM   2. Setup.exe --uninstall: the registration and the stable copy gone;
REM   3. an editor holding the Marketplace copy: left alone (no install over
REM      it, which would pin it), and the MCP server left to that copy.
REM
REM   smoke_test_setup.bat <folder holding Setup.exe and the rest of the zip>
REM
REM Why it exists: the zip layout (build_setup_zip.bat) and the paths Setup.exe
REM looks in (install\Install.dpr) are edited independently. When the
REM repository's register-mcp.ps1 moved into scripts\, the installer's lookup
REM next to itself moved too, and 0.7.0 to 0.7.2 shipped a Setup.exe that
REM silently skipped the MCP registration. Nothing failed: it printed a line.
REM
REM The runs touch nothing on this machine. The folder is copied, so the zip's
REM contents are not changed; USERPROFILE, LOCALAPPDATA and APPDATA point into
REM a scratch folder under %TEMP%; PATH holds Windows itself plus stand-ins
REM for the claude and code CLIs (setup-smoke\), which log their calls and
REM keep a registry in the sandbox.
setlocal
if "%~1"=="" (
  echo usage: smoke_test_setup.bat ^<folder holding Setup.exe^>
  exit /b 2
)
if not exist "%~1\Setup.exe" (
  echo ERROR: no Setup.exe in "%~1"
  exit /b 2
)

set "SANDBOX=%TEMP%\delphi-debugger-setup-smoke"
if exist "%SANDBOX%" rmdir /s /q "%SANDBOX%"
mkdir "%SANDBOX%\zip" "%SANDBOX%\bin-claude" "%SANDBOX%\bin-code"
xcopy /E /I /Y /Q "%~1" "%SANDBOX%\zip" >nul
if errorlevel 1 (
  echo ERROR: could not copy "%~1" into the sandbox.
  exit /b 1
)
copy /Y "%~dp0setup-smoke\claude.cmd" "%SANDBOX%\bin-claude\" >nul
copy /Y "%~dp0setup-smoke\code.cmd" "%SANDBOX%\bin-code\" >nul

set FAILED=0
set "STABLE=%SANDBOX%\home\local\DelphiWin64Debugger"

REM ---------------------------------------------------------- 1. install --
call :fresh_home
call :run_setup install "%SANDBOX%\bin-claude"
call :expect_in_log install "Mode: portable" "Setup.exe did not run in portable mode from the zip layout."
call :expect_in_log install "Registering MCP server" "Setup.exe did not run register-mcp.ps1."
if not exist "%STABLE%\DelphiDebuggerMcp.exe" call :fail "the MCP server was not installed into the stable folder."
findstr /I /C:"DelphiWin64Debugger\DelphiDebuggerMcp.exe" "%SMOKE_FAKES%\delphi-debugger.reg" >nul 2>nul || call :fail "Claude Code was not given the stable copy as delphi-debugger."

REM -------------------------------------------------------- 2. uninstall --
call :run_setup uninstall "%SANDBOX%\bin-claude" --uninstall
call :expect_in_log uninstall "Mode: uninstall" "Setup.exe --uninstall did not run."
if exist "%SMOKE_FAKES%\delphi-debugger.reg" call :fail "--uninstall left delphi-debugger registered with Claude Code."
if exist "%STABLE%" call :fail "--uninstall left the stable folder %STABLE%."

REM ------------------------------------- 3. a Marketplace copy in VS Code --
call :fresh_home
mkdir "%SANDBOX%\home\.vscode\extensions"
>"%SANDBOX%\home\.vscode\extensions\extensions.json" echo [{"identifier":{"id":"mca-software.delphi-debugger"},"version":"9.9.9","metadata":{"source":"gallery"}}]
call :run_setup marketplace "%SANDBOX%\bin-claude;%SANDBOX%\bin-code"
call :expect_in_log marketplace "from the Marketplace" "Setup.exe did not recognise the Marketplace copy."
findstr /C:"--install-extension" "%SMOKE_FAKES%\code.log" >nul 2>nul && call :fail "Setup.exe installed its .vsix over the Marketplace copy."
if exist "%STABLE%\DelphiDebuggerMcp.exe" call :fail "Setup.exe installed its MCP server next to a Marketplace copy that keeps its own."

if %FAILED%==1 (
  echo ---- Setup.exe output, per run ----
  for %%L in (install uninstall marketplace) do (
    echo ==== %%L ====
    if exist "%SANDBOX%\%%L.log" type "%SANDBOX%\%%L.log"
  )
  echo ----------------------------------
  exit /b 1
)
echo Setup.exe smoke test passed: install registers the MCP server, --uninstall removes it, a Marketplace copy is left alone.
rmdir /s /q "%SANDBOX%"
exit /b 0

REM ----------------------------------------------------------------------------
:fresh_home
if exist "%SANDBOX%\home" rmdir /s /q "%SANDBOX%\home"
if exist "%SANDBOX%\fakes" rmdir /s /q "%SANDBOX%\fakes"
mkdir "%SANDBOX%\home\local" "%SANDBOX%\home\roaming" "%SANDBOX%\fakes"
set "SMOKE_FAKES=%SANDBOX%\fakes"
exit /b 0

REM :run_setup <log name> <extra PATH> [Setup.exe arguments]
REM Answers "y" to the MCP prompt, then Enter at the final pause.
:run_setup
setlocal
set "USERPROFILE=%SANDBOX%\home"
set "LOCALAPPDATA=%SANDBOX%\home\local"
set "APPDATA=%SANDBOX%\home\roaming"
set "PATH=%~2;%SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\WindowsPowerShell\v1.0"
(echo y& echo.& echo.) | "%SANDBOX%\zip\Setup.exe" %3 > "%SANDBOX%\%~1.log" 2>&1
endlocal
exit /b 0

REM :expect_in_log <log name> <text> <failure message>
:expect_in_log
findstr /C:%2 "%SANDBOX%\%~1.log" >nul || call :fail %3
exit /b 0

:fail
echo SMOKE FAIL: %~1
set FAILED=1
exit /b 0
