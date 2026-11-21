$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$installation=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installation) { throw 'Visual C++ Build Tools is required' }
$dev=Join-Path $installation 'Common7\Tools\Launch-VsDevShell.ps1'
& $dev -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$output=Join-Path $root 'runtime\windows-ime'
[void][IO.Directory]::CreateDirectory($output)
Push-Location $output
try {
    & cl.exe /nologo /O2 /W4 /WX /LD (Join-Path $PSScriptRoot 'WindowsIme.c') /link /OUT:LoomWindowsIme.dll imm32.lib user32.lib
    if ($LASTEXITCODE -ne 0) { throw 'Windows IME helper compilation failed' }
} finally { Pop-Location }
