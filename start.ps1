param([switch]$Gui, [switch]$Headless)
$ErrorActionPreference = 'Stop'
if ($Gui -and $Headless) { throw 'Choose either -Gui or -Headless' }
$runtimeRoot = $PSScriptRoot
$settings = Get-Content -LiteralPath (Join-Path $runtimeRoot 'config\runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ipc = Join-Path $runtimeRoot $settings.paths.ipc
$logs = Join-Path $runtimeRoot $settings.paths.logs
$statusFile = Join-Path $ipc 'runtime-status.json'
$previousStatusFile = $statusFile
if (-not (Test-Path -LiteralPath $previousStatusFile)) {
    $previousStatusFile = Join-Path $ipc 'bridge-ready.json'
}
if (Test-Path -LiteralPath $previousStatusFile) {
    $previous = Get-Content -LiteralPath $previousStatusFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($previous.status -in @('ready','starting','stopping')) {
        $running = Get-CimInstance Win32_Process -Filter "ProcessId=$($previous.pid)" -ErrorAction SilentlyContinue
        $legacyHost = $running -and $running.CommandLine -like '*src\bridge\serve-codex.mjs*'
        $directHost = $running -and $running.ExecutablePath -eq (Join-Path $runtimeRoot $settings.paths.engineExecutable) -and
            $running.CommandLine -like '*src\runtime\direct-bootstrap.st*'
        if ($legacyHost -or $directHost) {
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
$legacyCodexHome = Join-Path $runtimeRoot 'state\codex'
foreach ($variable in @('CODEX_HOME','CODEX_SQLITE_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($variable, 'Process')
    if ($value -and [IO.Path]::GetFullPath($value) -eq $legacyCodexHome) {
        [Environment]::SetEnvironmentVariable($variable, $null, 'Process')
    }
}
$migrationReceipt = Join-Path $runtimeRoot 'state\sessions\codex-home-migrated.json'
$previousMigrationReceipt = Join-Path $runtimeRoot 'state\bridge\codex-home-migrated.json'
if (-not (Test-Path -LiteralPath $migrationReceipt) -and
    -not (Test-Path -LiteralPath $previousMigrationReceipt) -and
    (Test-Path -LiteralPath (Join-Path $legacyCodexHome 'state_5.sqlite'))) {
    $codexExecutable = Join-Path $runtimeRoot $settings.paths.codexExecutable
    if (Get-CimInstance Win32_Process -Filter "Name='codex.exe'" | Where-Object { $_.ExecutablePath -eq $codexExecutable }) {
        throw 'The previous Loom Codex App Server is still running. Wait for saved shutdown before migrating.'
    }
    & (Join-Path $runtimeRoot $settings.paths.nodeExecutable) (Join-Path $runtimeRoot 'src\runtime\migrate-codex-home.mjs') |
        Add-Content -LiteralPath (Join-Path $logs 'codex-home-migration.log') -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw 'Codex home migration failed. See launcher-start.stderr.log.' }
}
if ($Gui -or $Headless) {
    $settings | Add-Member -NotePropertyName gui -NotePropertyValue ([bool]$Gui) -Force
    [System.IO.File]::WriteAllText((Join-Path $runtimeRoot 'config\runtime.json'), ($settings | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
}
$stop = Join-Path $ipc 'stop.json'
if (Test-Path -LiteralPath $stop) { Remove-Item -LiteralPath $stop }
$arguments = '"' + $runtimeRoot + '"'
$supervisorFile = Join-Path $runtimeRoot 'runtime\supervisor\LoomSupervisor.exe'
$supervisorSources = Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'src\supervisor') -File
if (-not (Test-Path -LiteralPath $supervisorFile) -or ($supervisorSources | Where-Object {
    $_.LastWriteTimeUtc -gt (Get-Item -LiteralPath $supervisorFile).LastWriteTimeUtc
})) {
    if ($previous -and $previous.supervisorPid) {
        $priorSupervisor = Get-Process -Id $previous.supervisorPid -ErrorAction SilentlyContinue
        if ($priorSupervisor -and $priorSupervisor.Path -eq $supervisorFile -and -not $priorSupervisor.WaitForExit(8000)) {
            throw 'The previous Loom supervisor has not exited.'
        }
    }
    $stagedSupervisor = Join-Path $runtimeRoot 'runtime\supervisor\pending\LoomSupervisor.exe'
    if ((Test-Path -LiteralPath $stagedSupervisor) -and -not ($supervisorSources | Where-Object {
        $_.LastWriteTimeUtc -gt (Get-Item -LiteralPath $stagedSupervisor).LastWriteTimeUtc
    })) {
        if (Test-Path -LiteralPath $supervisorFile) {
            [IO.File]::Replace($stagedSupervisor, $supervisorFile, [NullString]::Value)
        } else {
            [IO.File]::Move($stagedSupervisor, $supervisorFile)
        }
    } else {
        & (Join-Path $runtimeRoot 'src\supervisor\build.ps1')
    }
}
$process = Start-Process -FilePath $supervisorFile -ArgumentList $arguments -WorkingDirectory $runtimeRoot -WindowStyle Hidden -PassThru
$deadline = (Get-Date).AddSeconds(30)
do {
    Start-Sleep -Milliseconds 150
    $process.Refresh()
    if ($process.HasExited) { throw "Startup failed; see $logs\supervisor.log and $logs\runtime.stderr.log" }
    if (Test-Path -LiteralPath $statusFile) {
        $current = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($current.supervisorPid -eq $process.Id -and $current.status -eq 'ready') { $current | ConvertTo-Json; exit 0 }
        if ($current.supervisorPid -eq $process.Id -and $current.status -eq 'failed') { throw $current.error }
    }
} while ((Get-Date) -lt $deadline)
throw "Startup still pending; inspect $statusFile"
