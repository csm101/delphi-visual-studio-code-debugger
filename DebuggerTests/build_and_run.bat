@echo off
cd /d %~dp0
call rsvars.bat

echo.
echo === Build Adapter ===
call ..\scripts\build_dap.bat
if errorlevel 1 ( echo FAILED: Adapter & exit /b 1 )
rem scripts/build_dap.bat -> rsvars.bat -> dcc64 chain can leave cwd outside
rem this script's folder; use absolute paths for subsequent calls so
rem relative lookups don't fail when cwd has drifted.

echo.
echo === Build MCP Server ===
call "%~dp0..\scripts\build_mcp.bat"
if errorlevel 1 ( echo FAILED: MCP Server & exit /b 1 )

echo.
echo === Build TestPackage ===
call "%~dp0build_package.bat"
if errorlevel 1 ( echo FAILED: TestPackage & exit /b 1 )

echo.
echo === Build TestTarget (every debuggee fixture, both bitnesses) ===
rem Delegate to build_target.bat rather than repeating the dcc lines here. This
rem block WAS a copy, and it went stale exactly the way the RunTests copy did:
rem it built TestTarget, the two no-debug modules and TdsSample, and silently
rem skipped MapOnlyGlobals, NestedEnumSample, NoSourceStop and
rem InstructionStepSample. A fixture that is never rebuilt fails as "Timeout
rem waiting for stopped event" -- the breakpoint line no longer matches the
rem compiled binary -- which reads as a defect in the debugger rather than a
rem stale exe (docs/TRAPS.md, the stale-fixture trap).
rem build_target.bat also builds the ExcNestFixture debuggee (DevTools\Fixtures),
rem so it is not invoked separately here.
call "%~dp0build_target.bat"
if errorlevel 1 ( echo FAILED: TestTarget & exit /b 1 )

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
rem search paths after they moved out of RunTests.cfg into scripts/setpaths.bat).
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
