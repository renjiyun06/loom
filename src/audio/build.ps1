$ErrorActionPreference = 'Stop'
$runtimeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$output = Join-Path $runtimeRoot 'runtime\audio\AudioHost.exe'
New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
& 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' /nologo /target:exe /platform:x64 /optimize+ /r:System.Windows.Forms.dll "/out:$output" (Join-Path $PSScriptRoot 'AudioHost.cs')
if ($LASTEXITCODE -ne 0) { throw 'Audio host compilation failed' }
