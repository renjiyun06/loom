$ErrorActionPreference = 'Stop'
$installDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../runtime/mermaid'))
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
foreach ($manifest in @('package.json', 'package-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $manifest) -Destination $installDir
}
Push-Location -LiteralPath $installDir
try {
    & npm.cmd ci --ignore-scripts --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) { throw 'Mermaid dependency installation failed.' }
} finally {
    Pop-Location
}
