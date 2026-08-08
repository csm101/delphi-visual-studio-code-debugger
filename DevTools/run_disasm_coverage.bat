@echo off
rem Runs DisasmCoverage.exe with the Visual Studio 2026 toolset initialised
rem first, so dumpbin.exe is on PATH and DisasmCoverage does not need
rem -dumpbin. All arguments are passed straight through.
rem
rem Usage:
rem   DevTools\run_disasm_coverage.bat <module1> [<module2> ...] [-maxspan N] [-sample N] [-maxdivs N]
cd /d %~dp0
call "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=x64 >nul 2>&1
if not exist Win64\Debug\DisasmCoverage.exe (
  echo DisasmCoverage.exe not built -- run DevTools\build_all.bat first.
  exit /b 1
)
Win64\Debug\DisasmCoverage.exe %*
