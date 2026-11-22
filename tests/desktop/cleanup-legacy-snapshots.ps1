# One-time migration of the old saved-shutdown backups, after normal shutdown.
$ErrorActionPreference='Stop'
$root='D:\Loom'
$status=Get-Content -LiteralPath (Join-Path $root 'ipc\runtime-status.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($status.status -ne 'stopped' -or -not $status.saved) { throw 'Require a confirmed saved shutdown before migration' }
foreach ($runtimePid in @($status.pid,$status.enginePid,$status.codexPid)) {
    if ($runtimePid -and (Get-Process -Id $runtimePid -ErrorAction SilentlyContinue)) { throw "Runtime process still exists: $runtimePid" }
}
& (Join-Path $root 'runtime\node\node.exe') --input-type=module -e 'import {CheckpointStorage} from "file:///D:/Loom/src/tools/checkpoint-storage.mjs"; console.log(JSON.stringify({verified:new CheckpointStorage("D:/Loom").verify().pointer.id}));'
if ($LASTEXITCODE -ne 0) { throw 'Recovery verification failed; no backups removed' }
$expected=Join-Path $root 'backups\snapshots'
$base=Get-Item -LiteralPath $expected -Force
if ($base.FullName -ne $expected -or ($base.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected backup root' }
$removed=@(); $skipped=@(); [long]$bytes=0
foreach ($directory in Get-ChildItem -LiteralPath $base.FullName -Directory -Force) {
    $target=$directory.FullName
    if ($directory.Name -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z$' -or
        $directory.Parent.FullName -ne $base.FullName -or
        -not $target.StartsWith($expected+'\',[StringComparison]::OrdinalIgnoreCase) -or
        ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $skipped+=$target; continue }
    $children=@(Get-ChildItem -LiteralPath $target -Recurse -Force)
    if (@($children|Where-Object {($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.PSIsContainer -or $_.Name -notin @('main.image','main.changes')}).Count) {
        $skipped+=$target;continue
    }
    $bytes+=($children|Measure-Object Length -Sum).Sum
    Remove-Item -LiteralPath $target -Recurse -Force
    $removed+=$target
}
$result=[pscustomobject]@{checkedAt=[DateTimeOffset]::Now.ToString('o');removed=$removed;removedBytes=$bytes;skipped=$skipped}
[IO.File]::WriteAllText((Join-Path $root 'tests\results\checkpoint-optimization\legacy-backup-cleanup.json'),($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
$result|Select-Object checkedAt,@{n='removedCount';e={$_.removed.Count}},removedBytes,skipped|ConvertTo-Json
