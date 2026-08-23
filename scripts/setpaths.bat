@echo off
rem Resolves the third-party source roots this repo compiles against, so that a
rem fresh clone on a different machine can build without editing .cfg files.
rem
rem   call setpaths.bat jcl           - require the JCL sources
rem   call setpaths.bat jcl dunitx    - require JCL and DUnitX
rem   call setpaths.bat jcl-optional  - use the JCL sources if present, else skip
rem
rem Override the locations from the environment:
rem   set JCL_ROOT=D:\src\jcl\jcl\source
rem   set DUNITX_ROOT=D:\src\DUnitX\Source
rem
rem On success it exports the compiler flags:
rem   %JCL_FLAGS%      (empty when jcl-optional and JCL is absent)
rem   %DUNITX_FLAGS%
rem   %HAVE_JCL%       1 or 0

if "%JCL_ROOT%"==""    set JCL_ROOT=C:\Athens\jcl\jcl\source
if "%DUNITX_ROOT%"=="" set DUNITX_ROOT=C:\Athens\DUnitX\Source

set JCL_FLAGS=
set DUNITX_FLAGS=
set HAVE_JCL=0

if exist "%JCL_ROOT%\windows\JclDebug.pas" (
  set HAVE_JCL=1
  set JCL_FLAGS=-U"%JCL_ROOT%\windows;%JCL_ROOT%\common" -I"%JCL_ROOT%\include"
)

:parse
if "%~1"=="" goto done

if /i "%~1"=="jcl" (
  if "%HAVE_JCL%"=="0" (
    echo.
    echo ERROR: the JCL sources were not found.
    echo   looked for: %JCL_ROOT%\windows\JclDebug.pas
    echo.
    echo DebuggerCore\JclDebugReader.pas compiles against the JCL, so this is a
    echo hard dependency, not an optional extra.
    echo.
    echo   get them:  https://github.com/project-jedi/jcl
    echo   then:      set JCL_ROOT=^<path^>\jcl\source
    echo.
    exit /b 1
  )
)

if /i "%~1"=="jcl-optional" (
  if "%HAVE_JCL%"=="0" echo   (JCL not found at %JCL_ROOT% - skipping the tools that need it)
)

if /i "%~1"=="dunitx" (
  if not exist "%DUNITX_ROOT%\DUnitX.TestFramework.pas" (
    echo.
    echo ERROR: the DUnitX sources were not found.
    echo   looked for: %DUNITX_ROOT%\DUnitX.TestFramework.pas
    echo.
    echo   get them:  https://github.com/VSoftTechnologies/DUnitX
    echo   then:      set DUNITX_ROOT=^<path^>\Source
    echo.
    exit /b 1
  )
  set DUNITX_FLAGS=-U"%DUNITX_ROOT%" -I"%DUNITX_ROOT%"
)

shift
goto parse

:done
exit /b 0
