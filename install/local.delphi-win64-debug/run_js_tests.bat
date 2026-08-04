@echo off
rem Runs every JavaScript test in the extension folder.
rem
rem These cover the parts of the extension that are pure logic -- hover
rem expression spans, the GitHub update check, and the manifest/handler
rem agreement -- none of which needs VS Code running. The Delphi suite in
rem DebuggerTests does not touch them, so without this they only ever run when
rem someone remembers each file by name.
setlocal
cd /d %~dp0

where node >nul 2>&1
if errorlevel 1 (
  echo node was not found on PATH -- skipping the JavaScript tests.
  exit /b 0
)

set FAILED=0
for %%T in (test\*.test.js) do (
  echo.
  echo === %%T ===
  node "%%T"
  if errorlevel 1 set FAILED=1
)

echo.
if "%FAILED%"=="1" (
  echo JavaScript tests FAILED.
  exit /b 1
)
echo All JavaScript tests passed.
exit /b 0
