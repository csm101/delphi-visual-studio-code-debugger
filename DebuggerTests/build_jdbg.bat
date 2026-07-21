@echo off
rem Generates TestTarget.jdbg (JCL debug sidecar) from TestTarget.map so
rem JclDebugReaderTests can exercise the JCL provider. Gated on JCL presence:
rem when JCL is not installed this is skipped and the JCL tests self-skip.
cd /d %~dp0
call rsvars.bat
call ..\setpaths.bat jcl-optional
if "%HAVE_JCL%"=="0" (
  echo   [build_jdbg] JCL not present at %JCL_ROOT% -- skipping .jdbg generation
  exit /b 0
)
if not exist MakeJdbg\Win64\Debug md MakeJdbg\Win64\Debug
pushd MakeJdbg
dcc64 MakeJdbg.dpr %JCL_FLAGS% -E.\Win64\Debug -NU.\Win64\Debug 2>&1
set BERR=%errorlevel%
popd
if not "%BERR%"=="0" ( echo   [build_jdbg] MakeJdbg build FAILED & exit /b %BERR% )
MakeJdbg\Win64\Debug\MakeJdbg.exe "TestTarget\Win64\Debug\TestTarget.map"
exit /b %errorlevel%
