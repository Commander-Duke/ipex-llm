@echo off
setlocal

@REM Prefer bundled runtimes and avoid inheriting stale Intel device filters.
set "PATH=%~dp0;%~dp0lib\ollama;%~dp0lib\ollama\sycl;%PATH%"

@REM SYCL persistent cache can reduce warm-up time, but some recent Windows
@REM Intel runtime stacks become unstable when it is forced globally. Leave it
@REM as an opt-in environment override instead of enabling it by default.

@REM Shared-memory Intel iGPUs can report a huge VRAM figure and make Ollama
@REM pick an oversized default context. Keep a conservative default unless the
@REM user explicitly overrides OLLAMA_CONTEXT_LENGTH before launch. Preserve a
@REM legacy OLLAMA_NUM_CTX override for older wrappers.
if not defined OLLAMA_CONTEXT_LENGTH (
  if defined OLLAMA_NUM_CTX (
    set "OLLAMA_CONTEXT_LENGTH=%OLLAMA_NUM_CTX%"
  ) else (
    set "OLLAMA_CONTEXT_LENGTH=4096"
  )
)

set "OLLAMA_NUM_GPU=999"
set "OLLAMA_KEEP_ALIVE=-1"
set "OLLAMA_HOST=127.0.0.1:11434"
set "NO_PROXY=localhost,127.0.0.1"
set "no_proxy=localhost,127.0.0.1"
set "ZES_ENABLE_SYSMAN=1"
set "GIN_MODE=release"

@REM Newer Ollama discovery relies on /info from a child runner. On some
@REM Windows Intel iGPU systems a stale selector like ONEAPI_DEVICE_SELECTOR=level_zero:0
@REM prevents SYCL discovery entirely. The portable wrapper clears those filters.
set "ONEAPI_DEVICE_SELECTOR="
set "SYCL_DEVICE_FILTER="
set "ZE_AFFINITY_MASK="

cd /d %~dp0
ollama.exe serve
