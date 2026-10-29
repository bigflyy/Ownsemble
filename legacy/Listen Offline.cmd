@echo off
cd /d "%~dp0"
rem Open only the cached-audio window. No VK browser or private session is used.
set "proof_exe=%~dp0spikes\vk-flutter\build\windows\x64\runner\Release\ownsemble_flutter_proof.exe"
if not exist "%proof_exe%" (
  echo The offline test build is missing. Tell the agent to rebuild it.
  pause
  exit /b 1
)
start "" "%proof_exe%" --offline
