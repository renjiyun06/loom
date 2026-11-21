"Run with the official seed image in a separate VM, with no Codex or user draft."
Smalltalk globals at: #ExperimentRoot put: 'D:\Loom' asFileReference.
'D:\Loom\src\runtime\windows-ime.st' asFileReference fileIn.
((Smalltalk globals at: #LoomWindowsIme) positionWindow: ExternalAddress null x: 20 y: 400 width: 2 height: 24) = 0
 ifFalse: [ Error signal: 'Unexpected invalid-window result' ].
'D:\Loom\tests\results\ime-ffi.json' asFileReference writeStreamDo: [ :stream |
 stream nextPutAll: '{"isolatedEventLoopFfi":true,"invalidWindowHandled":true}' ].
Smalltalk snapshot: false andQuit: true.
