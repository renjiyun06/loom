Option Explicit
Dim shell, filesystem, runtimeRoot, command
Set shell = CreateObject("WScript.Shell")
Set filesystem = CreateObject("Scripting.FileSystemObject")
runtimeRoot = filesystem.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " & Chr(34) & runtimeRoot & "\open-loom.ps1" & Chr(34)
shell.Run command, 0, False
