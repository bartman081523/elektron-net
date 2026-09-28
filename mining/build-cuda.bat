@echo off
setlocal enabledelayedexpansion

rem Build the Elektron Net CUDA miner on Windows (elektron_miner_cuda.exe).
rem
rem Compiler strategy (mirrors build-cuda.sh):
rem   1. system nvcc, if a CUDA toolkit is installed
rem   2. otherwise: micromamba (bootstrapped if missing) + the environment
rem      "elektron-cuda" (nvcc 12.9 + libcurl + openssl from conda-forge)
rem
rem nvcc on Windows needs an MSVC host compiler (cl.exe). The script locates
rem Visual Studio / Build Tools via vswhere and imports vcvars64.bat so the
rem Windows SDK headers and libs are found. Prerequisite: Visual Studio 2019+
rem (or Build Tools) with the "Desktop development with C++" workload.
rem
rem Usage:    build-cuda.bat [output_dir]
rem Env vars: ELEK_CUDA_ARCH (default 75 = RTX 2060),
rem           ELEK_CUDA_FORCE_MICROMAMBA=1, ELEK_CUDA_ENV, ELEK_MAMBA_ROOT,
rem           ELEK_HOSTCC (cl.exe directory, overrides vswhere detection)

set ARCH=%ELEK_CUDA_ARCH%
if "%ARCH%"=="" set ARCH=75
set SRC_DIR=%~dp0
set OUT_DIR=%~1
if "%OUT_DIR%"=="" set OUT_DIR=%SRC_DIR%
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

set MAMBA_ROOT=%ELEK_MAMBA_ROOT%
if "%MAMBA_ROOT%"=="" set MAMBA_ROOT=%USERPROFILE%\micromamba
set ENV_DIR=%ELEK_CUDA_ENV%
if "%ENV_DIR%"=="" set ENV_DIR=%MAMBA_ROOT%\envs\elektron-cuda
set MAMBA_ROOT_PREFIX=%MAMBA_ROOT%
set MM=%MAMBA_ROOT%\bin\micromamba.exe

rem ---------------------------------------------------------------------------
rem Locate the MSVC host compiler (required by nvcc on Windows) and set up the
rem INCLUDE/LIB environment via vcvars64.bat.
rem ---------------------------------------------------------------------------
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :novs
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSROOT=%%i
if not defined VSROOT goto :novs
for /d %%D in ("%VSROOT%\VC\Tools\MSVC\*") do set MSVC_DIR=%%D
set HOSTCC=%ELEK_HOSTCC%
if "%HOSTCC%"=="" set HOSTCC=%MSVC_DIR%\bin\Hostx64\x64
if exist "%HOSTCC%\cl.exe" goto :havecl
:novs
echo ERROR: no Visual Studio C++ tools found. Install Visual Studio 2019+ or
echo Build Tools with the "Desktop development with C++" workload -- nvcc
echo needs cl.exe as its host compiler.
exit /b 1
:havecl
call "%VSROOT%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
    echo ERROR: vcvars64.bat failed for %VSROOT%
    exit /b 1
)

rem ---------------------------------------------------------------------------
rem Route 1: system nvcc
rem ---------------------------------------------------------------------------
where nvcc >nul 2>nul
if errorlevel 1 goto :micromamba
if "%ELEK_CUDA_FORCE_MICROMAMBA%"=="1" goto :micromamba

for /f "delims=" %%i in ('where nvcc') do set NVCC=%%i
echo using system nvcc: %NVCC%
"%NVCC%" -ccbin "%HOSTCC%" -O3 -std=c++20 -arch=sm_%ARCH% -Xptxas -v ^
    "%SRC_DIR%miner_cuda.cu" ^
    -o "%OUT_DIR%\elektron_miner_cuda.exe" ^
    -lcurl -lssl -lcrypto -lws2_32
if errorlevel 1 (
    echo system nvcc build failed -- is a libcurl/openssl SDK for MSVC installed?
    echo or force the self-contained route: set ELEK_CUDA_FORCE_MICROMAMBA=1 and re-run
    exit /b 1
)
echo built: %OUT_DIR%\elektron_miner_cuda.exe
exit /b 0

rem ---------------------------------------------------------------------------
rem Route 2: micromamba environment (bootstrapped on demand)
rem ---------------------------------------------------------------------------
:micromamba
if exist "%ENV_DIR%\bin\nvcc.exe" goto :envready
if exist "%ENV_DIR%\Library\bin\nvcc.exe" goto :envready
if exist "%MM%" goto :createenv

echo bootstrapping micromamba into %MAMBA_ROOT% ...
if not exist "%MAMBA_ROOT%" mkdir "%MAMBA_ROOT%"
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri 'https://micro.mamba.pm/api/micromamba/win-64/latest' -OutFile '%TEMP%\micromamba.tar.bz2'"
if errorlevel 1 (
    echo ERROR: downloading micromamba failed
    exit /b 1
)
tar -xjf "%TEMP%\micromamba.tar.bz2" -C "%MAMBA_ROOT%"
if errorlevel 1 (
    echo ERROR: extracting micromamba failed
    exit /b 1
)
del "%TEMP%\micromamba.tar.bz2"

:createenv
if exist "%ENV_DIR%\bin\nvcc.exe" goto :envready
if exist "%ENV_DIR%\Library\bin\nvcc.exe" goto :envready
echo creating CUDA build env "elektron-cuda" ...
"%MM%" create -y -n elektron-cuda -c nvidia -c conda-forge cuda-nvcc cuda-cudart-dev cuda-cudart cuda-cudart-static libcurl openssl "cuda-version=12.9"
if errorlevel 1 (
    echo ERROR: micromamba create failed
    exit /b 1
)

:envready
set NVCC=%ENV_DIR%\bin\nvcc.exe
if not exist "%NVCC%" set NVCC=%ENV_DIR%\Library\bin\nvcc.exe
if not exist "%NVCC%" (
    echo ERROR: nvcc.exe not found in %ENV_DIR%
    exit /b 1
)
echo using env nvcc: %NVCC%

"%NVCC%" -ccbin "%HOSTCC%" -O3 -std=c++20 -arch=sm_%ARCH% -Xptxas -v ^
    -I"%ENV_DIR%\include" -I"%ENV_DIR%\Library\include" ^
    -L"%ENV_DIR%\lib" -L"%ENV_DIR%\Library\lib" ^
    "%SRC_DIR%miner_cuda.cu" ^
    -o "%OUT_DIR%\elektron_miner_cuda.exe" ^
    -lcurl -lssl -lcrypto -lws2_32
if errorlevel 1 exit /b 1
echo built: %OUT_DIR%\elektron_miner_cuda.exe