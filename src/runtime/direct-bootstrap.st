"Start a supervised GT image that owns its Codex connection."
| root loader host oldHost previous deadline |
root := FileLocator workingDirectory.
loader := [ :name |
 | source digest fingerprints evaluate |
 source := String cr join: (root / 'src' / 'runtime' / name) contents lines.
 fingerprints := Smalltalk globals at: #LoomRuntimeSourceFingerprints ifAbsentPut: [ Dictionary new ].
 digest := SHA256 new hashMessage: source utf8Encoded.
 ((name = 'bootstrap.st') or: [
  (fingerprints at: name ifAbsent: [ nil ]) ~= digest ]) ifTrue: [
  evaluate := [ Smalltalk compiler evaluate: source ].
  [ evaluate value ] on: Error do: [ :error |
   (error signalerContext stack anySatisfy: [ :frame | frame receiver == File and: [ frame selector = #sizeOf: ] ])
    ifFalse: [ error pass ].
   [ Smalltalk openSourceFiles ] on: Error do: [ :opening | Smalltalk openSourceFiles ].
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
 (oldHost notNil or: [ previous notNil ]) ifTrue: [
  "Close the old buffered streams before reopening the live changes file."
  [ Smalltalk openSourceFiles ] on: Error do: [ :error | Smalltalk openSourceFiles ] ].
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
