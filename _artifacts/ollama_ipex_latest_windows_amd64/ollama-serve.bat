@echo off
setlocal

@REM Prefer bundled runtimes and avoid inheriting stale Intel device filters.
set "PATH=%~dp0;%~dp0lib\ollama;%~dp0lib\ollama\sycl;%PATH%"

set "OLLAMA_NUM_GPU=999"
set "OLLAMA_KEEP_ALIVE=-1"
set "OLLAMA_HOST=127.0.0.1:11434"
set "NO_PROXY=localhost,127.0.0.1"
set "no_proxy=localhost,127.0.0.1"
set "ZES_ENABLE_SYSMAN=1"
set "GIN_MODE=release"

@REM A stale selector like ONEAPI_DEVICE_SELECTOR=level_zero:0 can prevent
@REM SYCL discovery on Windows Intel iGPU systems and forces CPU fallback.
set "ONEAPI_DEVICE_SELECTOR="
set "SYCL_DEVICE_FILTER="
set "ZE_AFFINITY_MASK="

cd /d %~dp0
ollama.exe serve
