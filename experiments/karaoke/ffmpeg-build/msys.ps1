# Run one command line inside the separate MSYS2 for the karaoke ffmpeg build
# (plan 11 B1), in its UCRT64 environment, with a clean PATH (minimal: only
# Windows' own folders are inherited, so Git Bash and winget tools stay out).
# Usage: powershell -NoProfile -File msys.ps1 '<bash command line>'
param([Parameter(Mandatory = $true)][string]$Line)
$root = 'C:\MyProjects\Ownsemble\.local\v2-tools\msys2-video\msys64'
$env:MSYSTEM = 'UCRT64'
$env:CHERE_INVOKING = '1'
$env:MSYS2_PATH_TYPE = 'minimal'
$env:PATH = 'C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0'
Set-Location 'C:\MyProjects\Ownsemble\.local\v2-tools\video-build'
& "$root\usr\bin\bash.exe" -lc $Line
exit $LASTEXITCODE
