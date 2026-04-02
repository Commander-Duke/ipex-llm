@echo off

start "Ollama Serve" cmd /k "cd /d %~dp0 && call ollama-serve.bat"
