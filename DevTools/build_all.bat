@echo off
rem Builds every tool in this folder.
rem
rem Tools are DISCOVERED, not listed: every *.dpr here is built. Adding a tool
rem means dropping the .dpr in this folder - there is no list to keep in sync.
rem (The previous hand-maintained list had drifted: a third of the tools were
rem tracked in git but had no build stanza, so they could not be built at all
rem on a fresh clone.)

cd /d %~dp0
call rsvars.bat
call ..\setpaths.bat jcl-optional
if not exist Win64\Debug md Win64\Debug

rem Shared engine units live in ..\DebuggerCore (used by the DAP + MCP debuggers
rem and by these diagnostic tools). -U..\DebuggerCore resolves them + their
rem transitive deps for every tool below.
set FLAGS=-E.\Win64\Debug -NU.\Win64\Debug -NSSystem;Winapi;System.Win -U..\DebuggerCore
if "%HAVE_JCL%"=="1" set FLAGS=%FLAGS% %JCL_FLAGS%

rem Tools that do not compile without the upstream JCL sources.
set JCL_ONLY=TdsProbe JclProbe

set FAILED=

rem NOTE: the %%~xF guard is required - cmd's *.dpr wildcard also matches *.dproj
rem (8.3 short-name matching), which would build every project twice.
for %%F in (*.dpr) do if /i "%%~xF"==".dpr" call :build %%~nF
if not "%FAILED%"=="" goto failed

echo.
echo All DevTools built OK. Binaries in DevTools\Win64\Debug\
exit /b 0

:build
if "%HAVE_JCL%"=="0" (
  for %%J in (%JCL_ONLY%) do if /i "%%J"=="%~1" (
    echo === %~1 ===  (skipped: needs JCL^)
    exit /b 0
  )
)
echo === %~1 ===
dcc64 %~1.dpr %FLAGS% 2>&1
if errorlevel 1 set FAILED=%FAILED% %~1
exit /b 0

:failed
echo.
echo FAILED:%FAILED%
exit /b 1
