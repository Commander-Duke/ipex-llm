@echo off
for /f "delims=" %%i in ('python -c "import bigdl.cpp; print(bigdl.cpp.__file__)"') do set "cpp_file=%%i"
for %%a in ("%cpp_file%") do set "cpp_dir=%%~dpa"

set "cpp_dir=%cpp_dir:~0,-1%"
set "lib_dir=%cpp_dir%\libs"

:: Create symlinks for DLLs and EXE
for %%f in (ollama.exe ollama-lib.exe ollama_llama.dll ollama_ggml.dll ollama_llava_shared.dll ollama-ggml-base.dll ollama-ggml-cpu.dll ollama-ggml-sycl.dll libc++.dll) do (
    if exist "%cd%\%%f" del /f "%cd%\%%f"
    mklink "%cd%\%%f" "%lib_dir%\%%f"
)

:: Create symlink for dist directory
if exist "%cd%\dist" rmdir /s /q "%cd%\dist"
mklink /D "%cd%\dist" "%lib_dir%\dist"
