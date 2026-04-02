@echo off
setlocal
powershell -ExecutionPolicy Bypass -File "%~dp0build-ollama-ipex-latest.ps1" %*
