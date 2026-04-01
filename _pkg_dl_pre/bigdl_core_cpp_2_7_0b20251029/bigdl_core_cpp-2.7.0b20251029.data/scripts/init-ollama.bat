@echo off
for /f "delims=" %%i in ('python -c "import bigdl.cpp; print(bigdl.cpp.__file__)"') do set "cpp_file=%%i"
for %%a in ("%cpp_file%") do set "cpp_dir=%%~dpa"

set "cpp_dir=%cpp_dir:~0,-1%"
set "lib_dir=%cpp_dir%\libs\ollama"

:: Create symlinks for DLLs and EXE
for %%f in (ollama.exe ollama-lib.exe llama.dll ggml.dll llava_shared.dll ggml-base.dll ggml-cpu.dll ggml-sycl.dll mtmd_shared.dll libc++.dll) do (
    if exist "%cd%\%%f" del /f "%cd%\%%f"
    mklink "%cd%\%%f" "%lib_dir%\%%f"
)
