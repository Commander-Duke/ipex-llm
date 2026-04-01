@echo off
for /f "delims=" %%i in ('python -c "import bigdl.cpp; print(bigdl.cpp.__file__)"') do set "cpp_file=%%i"
for %%a in ("%cpp_file%") do set "cpp_dir=%%~dpa"

set "cpp_dir=%cpp_dir:~0,-1%"
set "lib_dir=%cpp_dir%\libs\llama_cpp"
set "destination_folder=%cd%"

pushd "%lib_dir%"
for %%f in (*) do (
    if not "%%f"=="ollama.exe" (
        if exist "%destination_folder%\%%~nxf" (
            del /f "%destination_folder%\%%~nxf"
        )
        mklink "%destination_folder%\%%~nxf" "%%~ff"
    )
)
popd

copy "%cpp_dir%\convert_hf_to_gguf.py" .
copy "%cpp_dir%\convert_hf_to_gguf_update.py" .
copy "%cpp_dir%\convert_llama_ggml_to_gguf.py" .
copy "%cpp_dir%\convert_lora_to_gguf.py" .
xcopy /E /I "%cpp_dir%\gguf-py\" .\gguf-py
