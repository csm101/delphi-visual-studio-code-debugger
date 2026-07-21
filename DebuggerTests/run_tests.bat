@echo off
cd /d %~dp0
Win64\Debug\RunTests.exe --xmlfile:Win64\Debug\TestResults.xml
exit /b %errorlevel%
