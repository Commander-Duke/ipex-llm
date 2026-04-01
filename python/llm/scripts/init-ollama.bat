@echo off
setlocal EnableExtensions

set "MODE=%IPEX_LLM_INIT_MODE%"
if "%MODE%"=="" set "MODE=copy"

for /f "delims=" %%i in ('python -c "import bigdl.cpp; print(bigdl.cpp.__file__)"') do set "CPP_FILE=%%i"
if "%CPP_FILE%"=="" (
    echo Failed to locate bigdl.cpp. Please make sure bigdl-core-cpp is installed. 1>&2
    exit /b 1
)

for %%a in ("%CPP_FILE%") do set "CPP_DIR=%%~dpa"
set "CPP_DIR=%CPP_DIR:~0,-1%"

set "SOURCE_DIR=%CPP_DIR%\libs\ollama"
set "LAYOUT=new"
if not exist "%SOURCE_DIR%\ollama.exe" (
    set "SOURCE_DIR=%CPP_DIR%\libs"
    set "LAYOUT=legacy"
)

if not exist "%SOURCE_DIR%\ollama.exe" (
    echo Failed to locate Ollama binaries under "%CPP_DIR%". 1>&2
    exit /b 1
)

echo Initializing Ollama from "%SOURCE_DIR%"
echo Init mode: %MODE%

if /I "%LAYOUT%"=="new" (
    for %%f in (ollama.exe ollama-lib.exe llama.dll ggml.dll llava_shared.dll ggml-base.dll ggml-cpu.dll ggml-sycl.dll mtmd_shared.dll libc++.dll) do (
        call :install_file "%%f" || exit /b 1
    )
) else (
    for %%f in (ollama.exe ollama-lib.exe ollama_llama.dll ollama_ggml.dll ollama_llava_shared.dll ollama-ggml-base.dll ollama-ggml-cpu.dll ollama-ggml-sycl.dll libc++.dll) do (
        call :install_file "%%f" || exit /b 1
    )
    if exist "%SOURCE_DIR%\dist" (
        call :install_dir "dist" || exit /b 1
    )
)

echo Complete.
exit /b 0

:install_file
set "NAME=%~1"
set "SRC=%SOURCE_DIR%\%NAME%"
set "DST=%CD%\%NAME%"

if not exist "%SRC%" (
    echo Missing source file "%SRC%". 1>&2
    exit /b 1
)

if exist "%DST%" del /f /q "%DST%" >nul 2>&1

if /I "%MODE%"=="symlink" (
    mklink "%DST%" "%SRC%" >nul 2>&1
    if not errorlevel 1 (
        echo Linked %NAME%
        exit /b 0
    )
    echo Symlink failed for %NAME%, falling back to copy.
)

copy /Y "%SRC%" "%DST%" >nul
if errorlevel 1 (
    echo Failed to copy "%SRC%" to "%DST%". 1>&2
    exit /b 1
)

echo Copied %NAME%
exit /b 0

:install_dir
set "NAME=%~1"
set "SRC=%SOURCE_DIR%\%NAME%"
set "DST=%CD%\%NAME%"

if exist "%DST%" rmdir /s /q "%DST%" >nul 2>&1

if /I "%MODE%"=="symlink" (
    mklink /D "%DST%" "%SRC%" >nul 2>&1
    if not errorlevel 1 (
        echo Linked %NAME%
        exit /b 0
    )
    echo Directory symlink failed for %NAME%, falling back to copy.
)

xcopy "%SRC%" "%DST%" /E /I /Y >nul
if errorlevel 1 (
    echo Failed to copy "%SRC%" to "%DST%". 1>&2
    exit /b 1
)

echo Copied %NAME%
exit /b 0
