@echo off
cd /d %~dp0
call rsvars.bat

echo.
echo === Build Adapter ===
call ..\build_dap.bat
if errorlevel 1 ( echo FAILED: Adapter & exit /b 1 )
rem build_dap.bat -> rsvars.bat -> dcc64 chain can leave cwd outside
rem this script's folder; use absolute paths for subsequent calls so
rem relative lookups don't fail when cwd has drifted.

echo.
echo === Build MCP Server ===
call "%~dp0..\build_mcp.bat"
if errorlevel 1 ( echo FAILED: MCP Server & exit /b 1 )

echo.
echo === Build TestPackage ===
call "%~dp0build_package.bat"
if errorlevel 1 ( echo FAILED: TestPackage & exit /b 1 )

echo.
echo === Build TestTarget ===
pushd TestTarget
if not exist Win64\Debug md Win64\Debug
dcc64 TestTarget.dpr 2>&1
if errorlevel 1 ( popd & echo FAILED: TestTarget & exit /b 1 )
rem No-debug DLL + EXE (built WITHOUT -V/-VR/-VN, debug switches off) so the
rem adapter sees modules with no symbols in any format -- exercises the
rem "no debug info" diagnostic and unverified-breakpoint handling.
dcc64 -$D- -$L- -$Y- -E.\Win64\Debug -NU.\Win64\Debug NoDebugLib.dpr 2>&1
if errorlevel 1 ( popd & echo FAILED: NoDebugLib & exit /b 1 )
dcc64 -$D- -$L- -$Y- -E.\Win64\Debug -NU.\Win64\Debug NoDebugExe.dpr 2>&1
if errorlevel 1 ( popd & echo FAILED: NoDebugExe & exit /b 1 )
rem External-TDS target: -VT emits debug info to a standalone .tds (no embedded
rem .debug section) so TD32ReaderTests can exercise LoadFromTdsFile.
dcc64 -$O- -VT -VN -E.\Win64\Debug -NU.\Win64\Debug TdsSample.dpr 2>&1
if errorlevel 1 ( popd & echo FAILED: TdsSample & exit /b 1 )
rem 32-bit build of the SAME sources for the Win32 target-support tests. The
rem .cfg hardcodes -E/-NU to Win64\Debug and dcc lets the command line win, so
rem these overrides redirect the output without forking the .cfg.
if not exist Win32\Debug md Win32\Debug
dcc32 -E.\Win32\Debug -NU.\Win32\Debug TestTarget.dpr 2>&1
if errorlevel 1 ( popd & echo FAILED: TestTarget ^(Win32^) & exit /b 1 )
popd

echo.
echo === Generate TestTarget.jdbg (JCL sidecar; skipped if JCL absent) ===
call "%~dp0build_jdbg.bat"
if errorlevel 1 ( echo FAILED: TestTarget.jdbg & exit /b 1 )

echo.
echo === Build TestHost + TestSubject.bpl (BPL parity scenario) ===
call "%~dp0build_host.bat"
if errorlevel 1 ( echo FAILED: TestHost & exit /b 1 )

echo.
echo === Build RunTests ===
rem Delegate to build_runner.bat rather than repeating the dcc64 line here:
rem the duplicate silently went stale once already (it missed the JCL/DUnitX
rem search paths after they moved out of RunTests.cfg into setpaths.bat).
call "%~dp0build_runner.bat"
if errorlevel 1 ( echo FAILED: RunTests & exit /b 1 )

echo.
echo === Build RunTestsParallel ===
call "%~dp0build_parallel_runner.bat"
if errorlevel 1 ( echo FAILED: RunTestsParallel & exit /b 1 )

echo.
echo === Run Tests ===
rem Several worker processes by default; the count adapts to the machine's cores
rem and free memory. Set RUNTESTS_JOBS=1 for the sequential path (identical
rem results, ~6x slower) whenever parallelism is suspected in a failure.
rem RUNTESTS_ONLY is passed through to every worker unchanged.
call "%~dp0run_tests_parallel.bat"
exit /b %errorlevel%
