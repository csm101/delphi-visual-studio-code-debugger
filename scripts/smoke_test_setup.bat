@echo off
REM Runs Setup.exe from a setup-zip layout the way a user would, in a sandbox,
REM and fails unless it installs AND registers the MCP server.
REM
REM   smoke_test_setup.bat <folder holding Setup.exe and the rest of the zip>
REM
REM Why it exists: the zip layout (build_setup_zip.bat) and the paths Setup.exe
REM looks in (install\Install.dpr) are edited independently. When the
REM repository's register-mcp.ps1 moved into scripts\, the installer's lookup
REM next to itself moved too, and 0.7.0 to 0.7.2 shipped a Setup.exe that
REM silently skipped the MCP registration. Nothing failed: it printed a line.
REM
REM The run touches nothing on this machine. The folder is copied, so the zip's
REM contents are not changed by the run; USERPROFILE, LOCALAPPDATA and APPDATA
REM point into a scratch folder under %TEMP%; PATH holds only Windows itself,
REM so no editor is detected and no claude CLI is found. The installer is
REM answered "y" to the MCP prompt and Enter at its final pause.
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
mkdir "%SANDBOX%\zip" "%SANDBOX%\home\local" "%SANDBOX%\home\roaming"
xcopy /E /I /Y /Q "%~1" "%SANDBOX%\zip" >nul
if errorlevel 1 (
  echo ERROR: could not copy "%~1" into the sandbox.
  exit /b 1
)

set "LOG=%SANDBOX%\setup.log"
set "STABLE=%SANDBOX%\home\local\DelphiWin64Debugger"
set "SYSROOT=%SystemRoot%"
setlocal
set "USERPROFILE=%SANDBOX%\home"
set "LOCALAPPDATA=%SANDBOX%\home\local"
set "APPDATA=%SANDBOX%\home\roaming"
set "PATH=%SYSROOT%\System32;%SYSROOT%;%SYSROOT%\System32\WindowsPowerShell\v1.0"
(echo y& echo.& echo.) | "%SANDBOX%\zip\Setup.exe" > "%LOG%" 2>&1
endlocal

set FAILED=0
findstr /C:"Mode: portable" "%LOG%" >nul || (echo SMOKE FAIL: Setup.exe did not run in portable mode from the zip layout. & set FAILED=1)
if not exist "%STABLE%\DelphiDebuggerMcp.exe" (echo SMOKE FAIL: the MCP server was not installed into %%LOCALAPPDATA%%\DelphiWin64Debugger. & set FAILED=1)
findstr /C:"Registering MCP server" "%LOG%" >nul || (echo SMOKE FAIL: Setup.exe did not run register-mcp.ps1. & set FAILED=1)

if %FAILED%==1 (
  echo ---- Setup.exe output ----
  type "%LOG%"
  echo --------------------------
  exit /b 1
)
echo Setup.exe smoke test passed: portable mode, MCP server installed and registered.
rmdir /s /q "%SANDBOX%"
exit /b 0
