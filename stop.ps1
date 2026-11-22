$ErrorActionPreference = 'Stop'
$statusFile = Join-Path $PSScriptRoot 'ipc\runtime-status.json'
if (-not (Test-Path -LiteralPath $statusFile)) { 'Runtime is not running'; exit 0 }
$current = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($current.status -notin @('ready','starting','stopping')) { $current | ConvertTo-Json; exit 0 }
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ipc\stop.json'), '{}')
$deadline = (Get-Date).AddSeconds(100)
do {
    Start-Sleep -Milliseconds 150
    $current = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
} while ($current.status -in @('ready','starting','stopping') -and (Get-Date) -lt $deadline)
$current | ConvertTo-Json
if ($current.status -ne 'stopped' -or -not $current.saved) { throw 'The runtime has not confirmed a saved shutdown; inspect logs.' }
