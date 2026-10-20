param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\build-output'))
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '..\source\dlls\sync\MnMChestSaveSync.cs'
$candidates = @((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'), (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
$csc = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw '.NET Framework csc.exe not found. Use Windows with .NET Framework.' }
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$output = Join-Path (Resolve-Path -LiteralPath $OutputDirectory).Path 'MnMChestSaveSync.exe'
& $csc '/nologo' '/optimize+' '/target:exe' '/platform:x64' '/reference:System.Core.dll' '/reference:System.Xml.dll' ("/out:" + $output) $source
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output)) { throw 'Compilation failed.' }
Write-Output ('Compiled only; executable was not launched: ' + $output)
