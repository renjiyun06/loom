"Start a supervised GT image that owns its Codex connection."
| root loader usesWorkingChanges reopenChanges host oldHost previous deadline |
root := FileLocator workingDirectory.
usesWorkingChanges := [
 | changes writer buffer binary file |
 changes := SourceFiles changesFileStream.
 (changes notNil and: [ changes isReadOnly not ]) and: [
  "SourceFile path reports the requested path, even when the opener used its fallback."
  writer := (changes instVarNamed: #stream) instVarNamed: #writeStream.
  buffer := writer instVarNamed: #stream.
  binary := buffer instVarNamed: #innerStream.
  file := binary instVarNamed: #file.
  file name asFileReference = Smalltalk changesFile asFileReference ] ].
reopenChanges := [
 | matches reopenDeadline |
 reopenDeadline := DateAndTime now + 5 seconds.
 [
  matches := [
   Smalltalk openSourceFiles.
   usesWorkingChanges value
  ] on: Error do: [ :error | false ].
  matches or: [ DateAndTime now >= reopenDeadline ]
 ] whileFalse: [ (Delay forMilliseconds: 50) wait ].
 matches ifFalse: [ Error signal: 'Could not reopen the working image changes file' ] ].
loader := [ :name |
 | source digest fingerprints evaluate |
 source := String cr join: (root / 'src' / 'runtime' / name) contents lines.
 fingerprints := Smalltalk globals at: #LoomRuntimeSourceFingerprints ifAbsentPut: [ Dictionary new ].
 digest := SHA256 new hashMessage: source utf8Encoded.
 ((name = 'bootstrap.st') or: [
  (fingerprints at: name ifAbsent: [ nil ]) ~= digest ]) ifTrue: [
  (name = 'bootstrap.st' or: [ usesWorkingChanges value ]) ifFalse: [ reopenChanges value ].
  evaluate := [ Smalltalk compiler evaluate: source ].
  [ evaluate value ] on: Error do: [ :error |
   (error signalerContext stack anySatisfy: [ :frame | frame receiver == File and: [ frame selector = #sizeOf: ] ])
    ifFalse: [ error pass ].
   reopenChanges value.
   evaluate value ].
  fingerprints at: name put: digest ] ].
loader value: 'bootstrap.st'.
Smalltalk globals at: #LoomRuntimeSourceLoader put: loader.
oldHost := Smalltalk globals removeKey: #LoomNativeCodexHost ifAbsent: [ nil ].
oldHost ifNotNil: #retire.
[
 previous := Smalltalk globals at: #BridgeInternalSnapshotProcess ifAbsent: [ nil ].
 previous ifNotNil: [
  deadline := DateAndTime now + 5 seconds.
  [ (Smalltalk globals at: #BridgeInternalSnapshotProcess ifAbsent: [ nil ]) == previous
   and: [ previous isTerminated not and: [ DateAndTime now < deadline ] ] ]
   whileTrue: [ (Delay forMilliseconds: 20) wait ] ].
 (oldHost notNil or: [ previous notNil or: [ Smalltalk globals includesKey: #LMConversation ] ]) ifTrue: [
  "The opener can fall back to the current directory before the old stream closes."
  reopenChanges value ].
 #('execution.st' 'native-lifecycle.st' 'platform-tools.st' 'sqlite.st' 'codex-client.st'
   'session-registry.st' 'codex-activity.st' 'codex-settings.st' 'codex-stdio.st'
   'codex-host.st' 'codex-controls.st' 'applications.st') do: loader.
 host := (Smalltalk globals at: #LMNativeCodexHost) new.
 Smalltalk globals at: #LoomNativeCodexHost put: host.
 host start
] on: Error do: [ :error |
 | file status |
 file := root / 'ipc' / 'bridge-ready.json'.
 status := STONJSON fromString: file contents.
 status at: 'status' put: 'failed'; at: 'error' put: error messageText.
 (Smalltalk globals at: #LMPlatformTools ifAbsent: [ nil ])
  ifNil: [ file writeStreamDo: [ :stream | stream nextPutAll: (STONJSON toString: status) ] ]
  ifNotNil: [ :tools | tools writeJSON: status to: file ].
 Smalltalk exitFailure ].
'Loom GT runtime started'
