@echo off
rem Stand-in for the VS Code CLI in scripts\smoke_test_setup.bat: installs
rem nothing, logs every call to %SMOKE_FAKES%\code.log.
echo %*>>"%SMOKE_FAKES%\code.log"
exit /b 0
