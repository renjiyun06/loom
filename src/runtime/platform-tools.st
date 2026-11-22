"On-demand Windows commands. GT owns their lifetime, standard I/O and timeout."
| cls |
cls := (Object << #LMPlatformTools slots: #(); package: 'Loom-Application') install.
cls class compile: 'builderFor: program arguments: arguments
 ^ (GtExternalProcessBuilder new: program asFileReference fullName)
 arguments: arguments; yourself'.
cls class compile: 'run: program arguments: arguments timeout: seconds
 | child timer output timedOut |
timedOut := false.
child := (self builderFor: program arguments: arguments) nullStdin; pipeStdout; pipeStderr; spawn.
child terminateOnShutdown.
timer := [
 (Delay forSeconds: seconds) wait.
 timedOut := true.
 [ child terminate ] on: Error do: [ :error | nil ]
] fork.
[ output := child waitAsyncWithOutput ] ensure: [ timer terminate ].
timedOut ifTrue: [ self error: ''本地工具执行超时'' ].
output status isSuccess ifFalse: [ self error: (output stderrStringLossy trimBoth ifEmpty: [ ''本地工具执行失败'' ]) ].
^ output stdoutString'.
cls class compile: 'interactive: program arguments: arguments
 | child |
child := (self builderFor: program arguments: arguments) pipeStdin; pipeStdout; nullStderr; spawn.
child terminateOnShutdown.
^ child'.
cls class compile: 'selectFiles
 | script executable encoded stdout |
script := ''$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
$picker = [Windows.Forms.OpenFileDialog]::new()
try {
  $picker.Title = "选择附件"
  $picker.Multiselect = $true
  $picker.Filter = "所有文件|*.*"
  $files = @()
  if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $files = $picker.FileNames }
  ConvertTo-Json -Compress -InputObject $files
} finally { $picker.Dispose() }''.
executable := (OSEnvironment current at: ''SystemRoot'') asFileReference
 / ''System32'' / ''WindowsPowerShell'' / ''v1.0'' / ''powershell.exe''.
encoded := ZnBase64Encoder new encode:
 (ByteArray streamContents: [ :bytes |
  | codec |
  codec := ZnUTF16Encoder newForEncoding: ''utf-16le''.
  script do: [ :character | codec nextPut: character toStream: bytes ] ]).
stdout := self run: executable arguments: #(''-NoProfile'' ''-STA'' ''-EncodedCommand''), {encoded} timeout: 600.
^ STONJSON fromString: stdout'.
cls class compile: 'move: source to: target
 | from to |
from := Win32WideString fromString: source fullName.
to := Win32WideString fromString: target fullName.
^ self moveWide: from to: to'.
cls class compile: 'moveWide: source to: target
 ^ self ffiCall: #(uint32 MoveFileExW(Win32WideString source, Win32WideString target, uint32 9)) module: ''kernel32.dll'''.
cls class compile: 'writeJSON: value to: file
 | temporary |
file parent ensureCreateDirectory.
temporary := file parent / (UUID new asString, ''.tmp'').
[ temporary writeStreamDo: [ :stream | stream nextPutAll: (STONJSON toString: value) ].
 (self move: temporary to: file) = 0 ifTrue: [ self error: ''无法保存 '', file basename ]
] ensure: [ temporary ensureDelete ]'.
'Loom platform tools installed'
