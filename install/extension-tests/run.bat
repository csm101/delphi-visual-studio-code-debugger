@echo off
REM Runs the VS Code extension's unit tests. Requires Node (any recent version);
REM there is no build step, no bundler and no node_modules.
cd /d %~dp0
setlocal
set FAILED=0

echo === syntax check ===
for %%F in (..\local.delphi-win64-debug\*.js ..\local.delphi-win64-debug\media\*.js ..\local.delphi-win64-debug\test\*.js *.js) do (
  node --check "%%F" || set FAILED=1
)
echo.
echo === manifest ===
node test-manifest.js || set FAILED=1
echo.
echo === jsonc / launch.json editing ===
node test-jsonc-edit.js || set FAILED=1
echo.
echo === shared (machine-wide) rules file ===
node test-global-rules.js || set FAILED=1
echo.
echo === delphiProgress status bar ===
node test-progress.js || set FAILED=1
echo.
echo === exception-rules webview ===
node test-webview.js || set FAILED=1
echo.
echo === create a rule for this exception ===
node test-exception-rule.js || set FAILED=1
echo.
echo === attach process picker ===
node test-process-picker.js || set FAILED=1
echo.

REM These live next to the extension rather than here, because they exercise
REM functions exported from extension.js and updateCheck.js directly. They were
REM written with their own "node <file>" instruction and were consequently never
REM run by anything -- which is the same as not having them.
echo === hover expression spans ===
node ..\local.delphi-win64-debug\test\hoverExpression.test.js || set FAILED=1
echo.
echo === GitHub update check ===
node ..\local.delphi-win64-debug\test\updateCheck.test.js || set FAILED=1
echo.
echo === memory view: window arithmetic, diff, hex parsing ===
node ..\local.delphi-win64-debug\test\memoryView.test.js || set FAILED=1
echo.
echo === memory view: what the pane does across a stop ===
node ..\local.delphi-win64-debug\test\memoryPane.test.js || set FAILED=1
echo.
echo === modules tree: ordering, status and details ===
node ..\local.delphi-win64-debug\test\modulesView.test.js || set FAILED=1
echo.

if "%FAILED%"=="1" (
  echo EXTENSION TESTS FAILED
  exit /b 1
)
echo All extension tests passed.
exit /b 0
