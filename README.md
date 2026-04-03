# IPEX-LLM Community Refresh
<p>
  <b>English</b> | <a href="./README.zh-CN.md">Chinese (legacy upstream overview)</a>
</p>

A community-maintained continuation of the last public `ipex-llm` codebase, with a practical focus on modern Windows + Ollama support for Intel GPUs.

> [!IMPORTANT]
> This repository is not an official Intel or BigDL release. The goal of this refresh is simple: keep the Windows Intel GPU workflow alive, reproducible, and usable for the community.

> [!NOTE]
> The current refresh is Windows-first. The original Python, Docker, NPU, and Linux material is still preserved in this repository, but the most active work in this branch is centered on Windows Ollama and portable/runtime quality-of-life fixes.

> [!NOTE]
> Some inherited quickstart pages still describe older packaged builds. When an older page conflicts with this root README, treat this README as the current project status for the community refresh.

## Why this repo exists

The original project left behind a strong foundation, but the Windows Ollama path started lagging behind newer upstream models and newer Intel runtime behavior. This refresh keeps the parts many people still rely on:

- local Ollama inference on Intel iGPU and Arc GPUs
- support for newer model families on Windows
- better handling for large models on shared-memory systems
- reproducible Windows builds instead of one-off binaries
- clearer docs for real-world community use

## What changed in this refresh

- Updated the Windows Ollama path to a recent upstream snapshot of `ollama`, with synced `llama.cpp` sources in the local builder.
- Restored support for newer model families on Windows, including `qwen3.5`-based models.
- Improved Intel iGPU memory handling so the runtime can account for both dedicated and shared memory, which helps models larger than 10 GB load on systems that depend on shared memory.
- Added a reproducible Windows builder at [`python/llm/scripts/build-ollama-ipex-latest.ps1`](./python/llm/scripts/build-ollama-ipex-latest.ps1) that can build a modern `ollama.exe`, package the required runtimes, generate launch wrappers, and write build metadata.
- Added safer Windows launch wrappers with a default `OLLAMA_CONTEXT_LENGTH=4096`, legacy `OLLAMA_NUM_CTX` compatibility, opt-in `SYCL_CACHE_PERSISTENT`, and automatic cleanup of stale `ONEAPI_DEVICE_SELECTOR`, `SYCL_DEVICE_FILTER`, and `ZE_AFFINITY_MASK` variables.
- Added conservative embedding defaults so `/api/embed` does not inherit an oversized VRAM-based context choice on large shared-memory Intel iGPU systems.
- Improved [`python/llm/scripts/init-ollama.bat`](./python/llm/scripts/init-ollama.bat) so Windows users can initialize Ollama from packaged, upstream-style, or legacy binary layouts without needing admin rights by default.
- Relaxed the Windows `bigdl-core-cpp` dependency in [`python/llm/setup.py`](./python/llm/setup.py) so newer Windows binary builds can land without respinning the whole repo.
- Updated the Windows Ollama quickstart and portable guidance to document the new runtime behavior and troubleshooting notes.

## Start here

- Easiest no-install route: [`docs/mddocs/Quickstart/ollama_portable_zip_quickstart.md`](./docs/mddocs/Quickstart/ollama_portable_zip_quickstart.md)
- Package install + `init-ollama.bat`: [`docs/mddocs/Quickstart/ollama_quickstart.md`](./docs/mddocs/Quickstart/ollama_quickstart.md)
- Full Windows GPU install guide: [`docs/mddocs/Quickstart/install_windows_gpu.md`](./docs/mddocs/Quickstart/install_windows_gpu.md)
- Build your own fresh Windows Ollama package: [`python/llm/scripts/build-ollama-ipex-latest.ps1`](./python/llm/scripts/build-ollama-ipex-latest.ps1)
- Check your runtime environment: [`python/llm/scripts/README.md`](./python/llm/scripts/README.md)

## Typical Windows flow

1. Follow the Windows prerequisites in [`docs/mddocs/Quickstart/install_windows_gpu.md`](./docs/mddocs/Quickstart/install_windows_gpu.md).
2. Install or upgrade the C++ package path with `python -m pip install --pre --upgrade "ipex-llm[cpp]"`.
3. Run `init-ollama.bat` in the folder where you want the local Ollama binaries.
4. Start the server with `ollama serve` or use the packaged `start-ollama.bat`.
5. In a second prompt, run `ollama run <model>` and start testing.

## Recommended Windows defaults

- Use the generated `start-ollama.bat` or `ollama-serve.bat` when working from a packaged build.
- Leave `ONEAPI_DEVICE_SELECTOR` unset on single-iGPU systems unless you really need manual device routing.
- Increase `OLLAMA_CONTEXT_LENGTH` only when you need more context and have confirmed your system is stable with it.
- Treat `SYCL_CACHE_PERSISTENT=1` as an opt-in experiment, not a universal default.
- Keep `ollama.exe`, `lib/ollama`, and the generated batch files together in the same folder layout.

## Build provenance

The verified local Windows build currently generated from this repo was built from:

- `ollama` `main` at commit `a8292dd85f234ef52f8b477dbbefbf9517f58ef5`
- `llama.cpp` sync commit `ec98e2002`
- Go `1.24.1`
- `llvm-mingw` `20240619`

The builder writes this information to `build-metadata.json` inside the generated output folder.

## Key files behind the refresh

- [`python/llm/scripts/build-ollama-ipex-latest.ps1`](./python/llm/scripts/build-ollama-ipex-latest.ps1): reproducible Windows Ollama builder and wrapper generator
- [`python/llm/scripts/init-ollama.bat`](./python/llm/scripts/init-ollama.bat): admin-free Ollama initialization with copy and symlink modes
- [`python/llm/setup.py`](./python/llm/setup.py): Windows packaging rules for newer `bigdl-core-cpp` builds
- [`docs/mddocs/Quickstart/ollama_quickstart.md`](./docs/mddocs/Quickstart/ollama_quickstart.md): updated package install and `init-ollama.bat` guidance
- [`docs/mddocs/Quickstart/ollama_portable_zip_quickstart.md`](./docs/mddocs/Quickstart/ollama_portable_zip_quickstart.md): updated portable behavior, context, selector, and stability notes

## What is still included from the original project

This repository still contains the wider `ipex-llm` material that made the original project valuable:

- Python and PyTorch integration
- HuggingFace, LangChain, and LlamaIndex examples
- Docker guides
- NPU guides and examples
- legacy portable zip content
- upstream docs and example trees for CPU, GPU, and serving workflows

Useful entry points:

- [`docs/mddocs/README.md`](./docs/mddocs/README.md)
- [`python/llm/example`](./python/llm/example)
- [`docker/llm`](./docker/llm)
- [`python/llm/portable-zip`](./python/llm/portable-zip)

## Contributing and issue reports

Issues, validation reports, and pull requests are welcome.

If you report a bug, please include:

- Windows version
- Intel GPU model and driver version
- whether you used a packaged build or `init-ollama.bat`
- the model name you tried to load
- whether you changed `OLLAMA_CONTEXT_LENGTH`, `ONEAPI_DEVICE_SELECTOR`, or `SYCL_CACHE_PERSISTENT`
- relevant logs or the output of the environment check tools in [`python/llm/scripts/README.md`](./python/llm/scripts/README.md)

## License

This repository remains under the Apache 2.0 license. Original credits belong to the `ipex-llm` and BigDL authors; community maintenance in this refresh builds on top of that work.
