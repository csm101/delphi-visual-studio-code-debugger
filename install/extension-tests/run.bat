@echo off
REM Runs the VS Code extension's unit tests. Requires Node (any recent version);
REM there is no build step, no bundler and no node_modules.
cd /d %~dp0
setlocal
set FAILED=0

echo === syntax check ===
for %%F in (..\mca-software.delphi-debugger\*.js ..\mca-software.delphi-debugger\media\*.js ..\mca-software.delphi-debugger\test\*.js *.js) do (
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
echo === project-scoped rules files ===
node test-project-rules.js || set FAILED=1
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
echo === DDK debug target: mapping, locating ddk.exe, obtaining the target ===
node test-ddk-target.js || set FAILED=1
echo.
echo === DDK configuration provider and the old sideloaded copy ===
node test-ddk-provider.js || set FAILED=1
echo.
echo === step isolation: the auto-release toggle ===
node test-step-isolation.js || set FAILED=1
echo.
echo === MCP server distribution: stable copy, VS Code registry, Claude Code ===
node test-mcp-distribution.js || set FAILED=1
echo.

REM These live next to the extension rather than here, because they exercise
REM functions exported from extension.js and updateCheck.js directly. They were
REM written with their own "node <file>" instruction and were consequently never
REM run by anything -- which is the same as not having them.
echo === hover expression spans ===
node ..\mca-software.delphi-debugger\test\hoverExpression.test.js || set FAILED=1
echo.
echo === GitHub update check ===
node ..\mca-software.delphi-debugger\test\updateCheck.test.js || set FAILED=1
echo.
echo === memory view: window arithmetic, diff, hex parsing ===
node ..\mca-software.delphi-debugger\test\memoryView.test.js || set FAILED=1
echo.
echo === memory view: what the pane does across a stop ===
node ..\mca-software.delphi-debugger\test\memoryPane.test.js || set FAILED=1
echo.
echo === modules tree: ordering, status and details ===
node ..\mca-software.delphi-debugger\test\modulesView.test.js || set FAILED=1
echo.

if "%FAILED%"=="1" (
  echo EXTENSION TESTS FAILED
  exit /b 1
)
echo All extension tests passed.
exit /b 0
