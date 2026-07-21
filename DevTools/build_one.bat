@echo off
rem Build a single DevTools tool.
rem
rem   build_one.bat <ToolName> [OutDir]
rem
rem <ToolName>  base name of the .dpr (without extension)
rem [OutDir]    optional output directory (default .\Win64\Debug); use a private
rem             directory when several builds may run concurrently, so they do
rem             not race on the shared DCU cache.
rem
rem The upstream JCL units are added automatically when present; tools that do
rem not use them simply ignore the extra search paths.

cd /d %~dp0
call rsvars.bat

if "%~1"=="" (
  echo usage: build_one.bat ^<ToolName^> [OutDir]
  exit /b 2
)

set TOOL=%~1
set OUT=%~2
if "%OUT%"=="" set OUT=.\Win64\Debug
if not exist "%OUT%" md "%OUT%"

set FLAGS=-E"%OUT%" -NU"%OUT%" -NSSystem;Winapi;System.Win -U..\DebuggerCore

set JCLROOT=%JCL_ROOT%
if "%JCLROOT%"=="" set JCLROOT=C:\Athens\jcl\jcl\source
if exist "%JCLROOT%\windows\JclTD32.pas" (
  set FLAGS=%FLAGS% -U"%JCLROOT%\windows;%JCLROOT%\common" -I"%JCLROOT%\include"
)

echo === %TOOL% ===
dcc64 %TOOL%.dpr %FLAGS% 2>&1
if errorlevel 1 (
  echo FAILED: %TOOL%
  exit /b 1
)
echo OK: %OUT%\%TOOL%.exe
exit /b 0
