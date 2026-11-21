$ErrorActionPreference = 'Stop'
$runtimeRoot = $PSScriptRoot
$launcherMutex = New-Object System.Threading.Mutex($false, 'Local\LoomCodexEnvironmentLauncher')
$launcherOwned = $false
try {
    try { $launcherOwned = $launcherMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $launcherOwned = $true }
    if (-not $launcherOwned) { exit 0 }
    $logDirectory = Join-Path $runtimeRoot 'logs'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    # Start-Process -Wait waits for descendants too, including the running VM.
    # Invoke the startup script directly in this already-hidden PowerShell.
    # It returns at readiness; the supervisor continues independently.
    & (Join-Path $runtimeRoot 'start.ps1') -Gui 1> (Join-Path $logDirectory 'launcher-start.stdout.log') 2> (Join-Path $logDirectory 'launcher-start.stderr.log')
    if ($LASTEXITCODE -ne 0) { throw 'Startup failed. See logs\launcher-start.stderr.log.' }
    $live = Get-Content -LiteralPath (Join-Path $runtimeRoot 'ipc\bridge-ready.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    # A user may already have closed the newly opened window. That is success,
    # not a launcher failure, and must neither show an error nor relaunch it.
    if ($live.status -in @('stopping','stopped')) { exit 0 }
    if ($live.status -ne 'ready') { throw 'Loom did not become ready. See logs\service.stderr.log.' }
    $engineProcess = Get-Process -Id $live.enginePid -ErrorAction SilentlyContinue
    if (-not $engineProcess) { exit 0 }
    $configuration = Get-Content -LiteralPath (Join-Path $runtimeRoot 'config\runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($engineProcess.Path -ne (Join-Path $runtimeRoot $configuration.paths.engineExecutable)) { throw 'Unexpected Loom process identity.' }
    # The runtime may have no windows and no UI loop after its last window closes.
    # Reopen the environment and wait for its real HWND instead of trusting a
    # cached Process.MainWindowHandle (which may be zero or a helper window).
    $desktopText = & (Join-Path $runtimeRoot $configuration.paths.nodeExecutable) (Join-Path $runtimeRoot 'src\bridge\open-environment.mjs') 2> (Join-Path $logDirectory 'launcher-desktop.stderr.log')
    if ($LASTEXITCODE -ne 0) { throw 'Cannot open the desktop. See logs\launcher-desktop.stderr.log.' }
    $desktop = ($desktopText -join [Environment]::NewLine) | ConvertFrom-Json
    if (-not $desktop.ok -or -not $desktop.hwnd) { throw 'No native desktop window was confirmed.' }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LoomWindowActivation {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
}
'@
    $window = [IntPtr]([long]$desktop.hwnd)
    $windowOwner = [uint32]0
    [void][LoomWindowActivation]::GetWindowThreadProcessId($window, [ref]$windowOwner)
    if ($windowOwner -ne $live.enginePid) { throw 'Unexpected desktop window owner.' }
    $wasMinimized = [LoomWindowActivation]::IsIconic($window)
    # Window creation and saved placement restoration are asynchronous. Verify
    # a few settled samples rather than exiting while restore is still queued.
    $stableSamples = 0
    $showDeadline = (Get-Date).AddSeconds(3)
    do {
        if ([LoomWindowActivation]::IsIconic($window)) {
            [void][LoomWindowActivation]::ShowWindowAsync($window, 9)
        } else {
            [void][LoomWindowActivation]::ShowWindowAsync($window, 5)
        }
        Start-Sleep -Milliseconds 100
        if ([LoomWindowActivation]::IsWindowVisible($window) -and -not [LoomWindowActivation]::IsIconic($window)) {
            $stableSamples++
        } else { $stableSamples = 0 }
    } while ($stableSamples -lt 3 -and (Get-Date) -lt $showDeadline)
    if ($stableSamples -lt 3) { throw 'The desktop window did not restore to a visible state.' }
    $foregroundRequested = [LoomWindowActivation]::SetForegroundWindow($window)
    $receipt = [ordered]@{
        openedAt = [DateTimeOffset]::UtcNow.ToString('o')
        enginePid = $live.enginePid
        hwnd = $desktop.hwnd
        visible = [LoomWindowActivation]::IsWindowVisible($window)
        wasMinimized = $wasMinimized
        minimized = [LoomWindowActivation]::IsIconic($window)
        foregroundRequested = $foregroundRequested
    }
    [System.IO.File]::WriteAllText((Join-Path $logDirectory 'launcher-desktop.json'), ($receipt | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
} catch {
    $details = $_.Exception.Message
    $errorLog = Join-Path $runtimeRoot 'logs\launcher-error.log'
    Add-Content -LiteralPath $errorLog -Encoding UTF8 -Value ((Get-Date).ToString('o') + ' ' + $details)
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show($details + [Environment]::NewLine + $errorLog, 'Loom Runtime', 'OK', 'Error')
    exit 1
} finally {
    if ($launcherOwned) { $launcherMutex.ReleaseMutex() }
    $launcherMutex.Dispose()
}
