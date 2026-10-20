param([string]$Python = 'python', [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build-output'))
$ErrorActionPreference = 'Stop'
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$output = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'wcxbridge.dll'
Push-Location (Join-Path $PSScriptRoot '..\source\native')
try {
    & $Python '-m' 'ziglang' 'cc' '-target' 'x86_64-windows-gnu' '-O2' '-shared' '-Wall' '-Wextra' '-Werror' '-Wl,--strip-all' 'wcxbridge.c' '-o' $output
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw 'Compilation failed; the recorded toolchain requires ziglang/Zig.' }
} finally { Pop-Location }
Write-Output ('Compiled only; DLL was not loaded: ' + $output)
