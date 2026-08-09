@echo off
rem Runs the already-built suite with several concurrent workers.
rem
rem   run_tests_parallel.bat [N]
rem
rem N (or RUNTESTS_JOBS) fixes the worker count; without it the driver picks one
rem from the machine's cores and available memory. N=1 is the sequential path.
cd /d %~dp0

if not "%~1"=="" set RUNTESTS_JOBS=%~1

rem Warm the .idx symbol sidecars before the workers start. They are published
rem atomically, so a cold start is correct either way -- but N workers all
rem parsing the same .rsm at once is N times the work for one shared result.
if exist ..\DevTools\Win64\Debug\PrebuildIdx.exe (
  echo === Prebuilding .idx sidecars ===
  ..\DevTools\Win64\Debug\PrebuildIdx.exe "%~dp0" -r >nul 2>&1
)

Win64\Debug\RunTestsParallel.exe --xmlfile "%~dp0Win64\Debug\TestResults.xml"
exit /b %errorlevel%
