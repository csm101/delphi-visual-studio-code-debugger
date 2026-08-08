@echo off
rem Regenerates bin\x64\Zydis.dll from zydis.submodule.
rem NOT called by build_all.bat / build_dap.bat / build_debug.bat — those stay
rem Delphi-only. Run this manually whenever the pinned submodule commit changes.
rem
rem Needs: Visual Studio 2026 (MSVC toolset 14.51.36231) + its bundled CMake.
rem Both are reached through VsDevCmd.bat; neither cl nor cmake is on PATH.

cd /d %~dp0

set "VSDEVCMD=C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat"
set "CMAKE=C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"

if not exist "%VSDEVCMD%" (
  echo ERROR: VsDevCmd.bat not found at %VSDEVCMD%
  exit /b 1
)
if not exist "%CMAKE%" (
  echo ERROR: cmake.exe not found at %CMAKE%
  exit /b 1
)
if not exist "zydis.submodule\CMakeLists.txt" (
  echo ERROR: zydis.submodule is empty. Run:
  echo   git submodule update --init --recursive ThirdParty\Zydis\zydis.submodule
  exit /b 1
)

call "%VSDEVCMD%" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b 1

if exist build rmdir /s /q build
mkdir build
cd build

"%CMAKE%" -G "NMake Makefiles" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DZYDIS_BUILD_SHARED_LIB=ON ^
  -DZYDIS_BUILD_EXAMPLES=OFF ^
  -DZYDIS_BUILD_TOOLS=OFF ^
  -DZYDIS_BUILD_TESTS=OFF ^
  -DZYDIS_BUILD_MAN=OFF ^
  -DZYDIS_BUILD_DOXYGEN=OFF ^
  -DZYDIS_FEATURE_ENCODER=ON ^
  ..\zydis.submodule
if errorlevel 1 (
  cd ..
  exit /b 1
)

"%CMAKE%" --build . --config Release
if errorlevel 1 (
  cd ..
  exit /b 1
)

cd ..

if not exist bin\x64 mkdir bin\x64
copy /y build\Zydis.dll bin\x64\Zydis.dll >nul
if errorlevel 1 (
  echo ERROR: build\Zydis.dll not found — check the build log above.
  exit /b 1
)

for /f "tokens=1" %%H in ('certutil -hashfile bin\x64\Zydis.dll SHA256 ^| findstr /v "hash CertUtil"') do (
  echo %%H  Zydis.dll> bin\x64\Zydis.dll.sha256
  goto :hashdone
)
:hashdone

echo.
echo Built bin\x64\Zydis.dll
type bin\x64\Zydis.dll.sha256
