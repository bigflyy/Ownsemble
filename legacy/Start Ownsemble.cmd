@echo off
cd /d "%~dp0"
set "ownsemble_exe=%~dp0app\build\windows\x64\runner\Release\ownsemble.exe"
if not exist "%ownsemble_exe%" (
  echo The Ownsemble build is missing. Ask the agent to build it.
  pause
  exit /b 1
)
start "" "%ownsemble_exe%"
