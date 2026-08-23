@echo off
REM Build the distributable zip and create a DRAFT GitHub release for it.
REM
REM   make_release.bat                          build + draft release
REM   make_release.bat -DryRun                  render the notes only, change nothing
REM   make_release.bat -SkipBuild               reuse the zip already in dist\
REM   make_release.bat -Highlights whatsnew.md  file whose text becomes "What's new"
REM   make_release.bat -Verify                  AFTER publishing: check that the
REM                                             tag landed on the built commit
REM
REM The version comes from install\local.delphi-win64-debug\package.json.
REM Nothing is ever published automatically: the release is left as a draft.
REM PowerShell 7 when present, Windows PowerShell otherwise. The script itself
REM avoids cmdlets that are missing on older hosts, so either works.
setlocal
cd /d "%~dp0.."
where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_release.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_release.ps1" %*
)
exit /b %ERRORLEVEL%
