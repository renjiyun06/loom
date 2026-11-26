"On-demand Windows commands. GT owns their lifetime, standard I/O and timeout."
| cls |
cls := (Object << #LMPlatformTools slots: #(); package: 'Loom-Application') install.
cls class compile: 'builderFor: program arguments: arguments
 ^ (GtExternalProcessBuilder new: program asFileReference fullName)
 arguments: arguments; yourself'.
cls class compile: 'run: program arguments: arguments timeout: seconds
 ^ self run: program arguments: arguments input: nil timeout: seconds'.
cls class compile: 'run: program arguments: arguments input: input timeout: seconds
 | builder child timer output timedOut |
timedOut := false.
builder := self builderFor: program arguments: arguments.
input ifNil: [ builder nullStdin ] ifNotNil: [ builder pipeStdin ].
child := builder pipeStdout; pipeStderr; spawn.
child terminateOnShutdown.
timer := [
 (Delay forSeconds: seconds) wait.
 timedOut := true.
 [ child terminate ] on: Error do: [ :error | nil ]
] fork.
[
 [ input ifNotNil: [ [ child stdin nextPutAll: input ] ensure: [ child stdin close ] ].
   output := child waitAsyncWithOutput ]
  on: Error do: [ :error |
   [ child terminate ] on: Error do: [ :ignored | nil ].
   error pass ]
] ensure: [ timer terminate ].
timedOut ifTrue: [ self error: ''本地工具执行超时'' ].
output status isSuccess ifFalse: [ self error: (output stderrStringLossy trimBoth ifEmpty: [ ''本地工具执行失败'' ]) ].
^ output stdoutString'.
cls class compile: 'interactive: program arguments: arguments
 | child |
child := (self builderFor: program arguments: arguments) pipeStdin; pipeStdout; nullStderr; spawn.
child terminateOnShutdown.
^ child'.
cls class compile: 'selectFiles
 ^ self powerShellJSON: ''Add-Type -AssemblyName System.Windows.Forms
$picker = [Windows.Forms.OpenFileDialog]::new()
try {
  $picker.Title = "选择附件"
  $picker.Multiselect = $true
  $picker.Filter = "所有文件|*.*"
  $files = @()
  if ($picker.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $files = $picker.FileNames }
  ConvertTo-Json -Compress -InputObject $files
} finally { $picker.Dispose() }'' timeout: 600'.
cls class compile: 'powerShellJSON: command timeout: seconds
 | script executable encoded stdout |
script := ''$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
'', command.
executable := (OSEnvironment current at: ''SystemRoot'') asFileReference
 / ''System32'' / ''WindowsPowerShell'' / ''v1.0'' / ''powershell.exe''.
encoded := ZnBase64Encoder new encode:
 (ByteArray streamContents: [ :bytes |
  | codec |
  codec := ZnUTF16Encoder newForEncoding: ''utf-16le''.
  script do: [ :character | codec nextPut: character toStream: bytes ] ]).
stdout := self run: executable arguments: #(''-NoProfile'' ''-STA'' ''-EncodedCommand''), {encoded} timeout: seconds.
^ STONJSON fromString: stdout'.
cls class compile: 'openWithDefaultApplication: file
 | path |
 path := ZnBase64Encoder new encode: file fullName utf8Encoded.
 ^ self powerShellJSON: ''$start = New-Object System.Diagnostics.ProcessStartInfo
$start.FileName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'', path, ''"))
$start.UseShellExecute = $true
$process = [System.Diagnostics.Process]::Start($start)
if ($null -ne $process) { $process.Dispose() }
$true | ConvertTo-Json -Compress'' timeout: 15'.
cls class compile: 'clipboardAttachmentRequest
 | sequence png |
 sequence := self clipboardSequence.
 "CF_HDROP takes priority. Prefer text over the bitmap that accompanies formatted text."
 (self clipboardHasFormat: 15) ifTrue: [ ^ { 15. sequence } ].
 png := self clipboardFormatNamed: (Win32WideString fromString: ''PNG'').
 (png ~= 0 and: [ self clipboardHasFormat: png ]) ifTrue: [ ^ { png. sequence } ].
 (self clipboardHasFormat: 13) ifTrue: [ ^ nil ].
 "Windows can synthesize CF_BITMAP from CF_DIB and CF_DIBV5."
 (self clipboardHasFormat: 2) ifTrue: [ ^ { 2. sequence } ].
 ^ nil'.
cls class compile: 'clipboardHasFormat: format
 ^ (self clipboardFormatAvailable: format) ~= 0'.
cls class compile: 'clipboardFormatAvailable: format
 ^ self ffiCall: #(uint32 IsClipboardFormatAvailable(uint32 format)) module: ''user32.dll'''.
cls class compile: 'clipboardFormatNamed: name
 ^ self ffiCall: #(uint32 RegisterClipboardFormatW(Win32WideString name)) module: ''user32.dll'''.
cls class compile: 'clipboardSequence
 ^ self ffiCall: #(uint32 GetClipboardSequenceNumber()) module: ''user32.dll'''.
cls class compile: 'readClipboardAttachments: request imageAt: target
 | encodedPath result |
 encodedPath := ZnBase64Encoder new encode: target fullName utf8Encoded.
 result := self powerShellJSON:
  self clipboardReaderScript,
  (String lf join: {
   ''$expectedSequence = '', request second asString.
   ''$format = '', request first asString.
   ''$target = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'', encodedPath, ''"))''.
   self clipboardCaptureScript }) timeout: 15.
 result at: ''error'' ifPresent: [ :reason | self error: reason ].
 ^ result at: ''files'''.
cls class compile: 'clipboardReaderScript
 ^ ''Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.IO;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public static class LoomClipboardReader {
    [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr window);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint DragQueryFile(IntPtr handle, uint index, StringBuilder path, uint size);
    [DllImport("kernel32.dll")] private static extern UIntPtr GlobalSize(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern bool GlobalUnlock(IntPtr handle);

    public static string[] ReadFiles(IntPtr handle) {
        var paths = new string[DragQueryFile(handle, uint.MaxValue, null, 0)];
        for (uint index = 0; index < paths.Length; index++) {
            uint size = DragQueryFile(handle, index, null, 0) + 1;
            var path = new StringBuilder(checked((int)size));
            DragQueryFile(handle, index, path, size);
            paths[index] = path.ToString();
        }
        return paths;
    }

    public static byte[] ReadBytes(IntPtr handle) {
        var bytes = new byte[checked((int)GlobalSize(handle).ToUInt64())];
        IntPtr data = GlobalLock(handle);
        if (data == IntPtr.Zero) throw new IOException("无法读取剪贴板图片");
        try { Marshal.Copy(data, bytes, 0, bytes.Length); }
        finally { GlobalUnlock(handle); }
        return bytes;
    }

    public static void SaveImage(byte[] png, Bitmap bitmap, string target) {
        Directory.CreateDirectory(Path.GetDirectoryName(target));
        if (bitmap != null) {
            bitmap.Save(target, ImageFormat.Png);
            return;
        }
        using (var stream = new MemoryStream(png))
        using (var image = Image.FromStream(stream, false, true)) {
            image.Save(target, ImageFormat.Png);
        }
    }
}
"@
'''.
cls class compile: 'clipboardCaptureScript
 ^ ''$bitmap = $null
try {
  $opened = $false
  for ($attempt = 0; $attempt -lt 8; $attempt++) {
    if ([LoomClipboardReader]::OpenClipboard([IntPtr]::Zero)) { $opened = $true; break }
    Start-Sleep -Milliseconds 20
  }
  if (!$opened) { throw "剪贴板暂时无法读取，请再粘贴一次" }
  try {
    if ([LoomClipboardReader]::GetClipboardSequenceNumber() -ne $expectedSequence) {
      throw "剪贴板内容已更改，请再粘贴一次"
    }
    $data = [LoomClipboardReader]::GetClipboardData($format)
    if ($data -eq [IntPtr]::Zero) { throw "剪贴板附件暂时无法读取，请再粘贴一次" }
    if ($format -eq 15) { $paths = [LoomClipboardReader]::ReadFiles($data) }
    elseif ($format -eq 2) { $bitmap = [Drawing.Image]::FromHbitmap($data) }
    else { $png = [LoomClipboardReader]::ReadBytes($data) }
  } finally {
    [void][LoomClipboardReader]::CloseClipboard()
  }
  if ($format -eq 15) {
    $files = @($paths | Where-Object { [IO.File]::Exists($_) })
    if ($files.Length -eq 0) { throw "剪贴板里没有可附加的文件" }
  } else {
    [LoomClipboardReader]::SaveImage($png, $bitmap, $target)
    $files = @($target)
  }
  ConvertTo-Json -Compress -InputObject @{ files = $files }
} catch {
  ConvertTo-Json -Compress -InputObject @{ error = $_.Exception.Message }
} finally {
  if ($null -ne $bitmap) { $bitmap.Dispose() }
}'''.
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
 21 timesRepeat: [
  (self move: temporary to: file) ~= 0 ifTrue: [ ^ value ].
  (Delay forMilliseconds: 25) wait ].
 self error: ''无法保存 '', file basename
] ensure: [ temporary ensureDelete ]'.
'Loom platform tools installed'
