param([switch]$Gui, [switch]$Headless)
$ErrorActionPreference = 'Stop'
if ($Gui -and $Headless) { throw 'Choose either -Gui or -Headless' }
$runtimeRoot = $PSScriptRoot
$settings = Get-Content -LiteralPath (Join-Path $runtimeRoot 'config\runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ipc = Join-Path $runtimeRoot $settings.paths.ipc
$logs = Join-Path $runtimeRoot $settings.paths.logs
$statusFile = Join-Path $ipc 'bridge-ready.json'
if (Test-Path -LiteralPath $statusFile) {
    $previous = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($previous.status -in @('ready','starting','stopping')) {
        $running = Get-CimInstance Win32_Process -Filter "ProcessId=$($previous.pid)" -ErrorAction SilentlyContinue
        if ($running -and $running.CommandLine -like '*src\bridge\serve-codex.mjs*') {
            $modeChange = ($Gui -and -not $previous.gui) -or ($Headless -and $previous.gui)
            if (-not $modeChange) { $previous | ConvertTo-Json; exit 0 }
            & (Join-Path $runtimeRoot 'stop.ps1') | Out-Null
            Start-Sleep -Milliseconds 150
        }
    }
}
# A killed owner cannot run its cleanup handler. Reap only its recorded, verified children.
if ($previous) {
    foreach ($entry in @(
        @{id=$previous.enginePid; executable=(Join-Path $runtimeRoot $settings.paths.engineExecutable); argument=(Join-Path $runtimeRoot $settings.paths.image)},
        @{id=$previous.codexPid; executable=(Join-Path $runtimeRoot $settings.paths.codexExecutable); argument='app-server'}
    )) {
        if ($entry.id) {
            $child = Get-CimInstance Win32_Process -Filter "ProcessId=$($entry.id)" -ErrorAction SilentlyContinue
            if ($child -and $child.ExecutablePath -eq $entry.executable -and $child.CommandLine.Contains($entry.argument)) {
                & taskkill.exe /PID $entry.id /T /F | Out-Null
            }
        }
    }
}
New-Item -ItemType Directory -Path $ipc,$logs -Force | Out-Null
if ($Gui -or $Headless) {
    $settings | Add-Member -NotePropertyName gui -NotePropertyValue ([bool]$Gui) -Force
    [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'config\runtime.json'), ($settings | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}
$stop = Join-Path $ipc 'stop.json'
if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop }
$arguments = '"' + $runtimeRoot + '"'
$process = Start-Process -FilePath (Join-Path $runtimeRoot 'runtime\supervisor\supervisor.exe') -ArgumentList $arguments -WorkingDirectory $runtimeRoot -WindowStyle Hidden -PassThru
$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 150
    $process.Refresh()
    if ($process.HasExited) { throw "Startup failed; see $logs\service.stderr.log" }
    if (Test-Path -LiteralPath $statusFile) {
        $current = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($current.supervisorPid -eq $process.Id -and $current.status -eq 'ready') { $current | ConvertTo-Json; exit 0 }
        if ($current.supervisorPid -eq $process.Id -and $current.status -eq 'failed') { throw $current.error }
    }
} while ((Get-Date) -lt $deadline)
throw "Startup still pending; inspect $statusFile"
