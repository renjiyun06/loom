$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$output = Join-Path $root 'runtime\supervisor\LoomSupervisor.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
& $compiler /nologo /target:winexe /platform:x64 /optimize+ /r:System.Web.Extensions.dll "/out:$output" (Join-Path $PSScriptRoot 'Supervisor.cs') (Join-Path $PSScriptRoot 'Recovery.cs')
if ($LASTEXITCODE -ne 0) { throw 'Supervisor compilation failed' }
