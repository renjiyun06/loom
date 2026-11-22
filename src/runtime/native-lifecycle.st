"Unify native Save/Quit with committed recovery checkpoints."
| imageClass |
imageClass := Smalltalk class.
(Smalltalk globals includesKey: #LoomOriginalSnapshotMethod) ifFalse: [
 Smalltalk globals at: #LoomOriginalSnapshotMethod put: (imageClass >> #snapshot:andQuit:) ].
(Smalltalk globals includesKey: #LoomNativeActionMutex) ifFalse: [
 Smalltalk globals at: #LoomNativeActionMutex put: Mutex new ].
LMExecution class compile: 'nativeSnapshotDuring: block
 | previous |
 previous := Smalltalk globals at: #LoomInternalSnapshotProcess ifAbsent: [ nil ].
 Smalltalk globals at: #LoomInternalSnapshotProcess put: Processor activeProcess.
 ^ block ensure: [
  previous ifNil: [ Smalltalk globals removeKey: #LoomInternalSnapshotProcess ifAbsent: [] ]
   ifNotNil: [ Smalltalk globals at: #LoomInternalSnapshotProcess put: previous ] ]'.
LMExecution class compile: 'managedSnapshot: save andQuit: quit
 | id gate state request operation |
 (save or: [ quit ]) ifFalse: [ ^ false ].
 Processor activeProcess == LoomMailboxProcess ifTrue: [
  self error: ''Run native Save/Quit in a separate runtime Process'' ].
 ^ LoomNativeActionMutex critical: [
  id := UUID new asString. gate := Semaphore new.
  state := Dictionary new at: ''id'' put: id; at: ''gate'' put: gate;
   at: ''session'' put: LoomRuntimeSessionId; at: ''save'' put: save; at: ''quit'' put: quit; yourself.
  Smalltalk globals at: #LoomNativeAction put: state.
  [
   request := LoomIPC / ''native-actions'' / (id , ''.tmp'').
   request writeStreamDo: [ :stream |
    stream nextPutAll: (STONJSON toString: (Dictionary new at: ''id'' put: id;
     at: ''session'' put: LoomRuntimeSessionId; at: ''save'' put: save; at: ''quit'' put: quit; yourself)) ].
   request renameTo: id , ''.json''.
   gate wait.
   (state at: ''ok'' ifAbsent: [ false ]) ifFalse: [
    self error: (state at: ''error'' ifAbsent: [ ''Native save failed'' ]) ].
   operation := SnapshotOperation save: save andQuit: quit withSessionManager: SessionManager default.
   operation instVarNamed: ''isImageStarting'' put: (state at: ''restored'' ifAbsent: [ false ]).
   operation
  ] ensure: [ Smalltalk globals removeKey: #LoomNativeAction ifAbsent: [] ] ]'.
LMExecution class compile: 'completeNativeAction: id result: result
 | state |
 state := Smalltalk globals at: #LoomNativeAction ifAbsent: [ ^ false ].
 (state at: ''id'') = id ifFalse: [ ^ false ].
 result keysAndValuesDo: [ :key :value | state at: key put: value ].
 (state at: ''gate'') signal.
 ^ true'.
LMExecution class compile: 'restoreNativeAction
 | state |
 state := Smalltalk globals at: #LoomNativeAction ifAbsent: [
  Smalltalk globals removeKey: #BridgeNativeAction ifAbsent: [ ^ false ] ].
 (state at: ''session'') = LoomRuntimeSessionId ifTrue: [ ^ false ].
 "A committed image contains the waiting caller, never an instruction to quit again."
 state at: ''ok'' put: true; at: ''restored'' put: true.
 (state at: ''gate'') signal.
 ^ true'.
imageClass compile: 'snapshot: save andQuit: quit
 (Smalltalk globals at: #LoomInternalSnapshotProcess ifAbsent: [ nil ]) == Processor activeProcess
  ifTrue: [ ^ LoomOriginalSnapshotMethod valueWithReceiver: self arguments: {save. quit} ].
 ^ LMExecution managedSnapshot: save andQuit: quit'.
"GT requests are already asynchronous. Keep its pulse loop free while Loom saves a checkpoint."
BlParallelUniverse compile: 'snapshot: save andQuit: quit
 ^ [ Smalltalk snapshot: save andQuit: quit ] fork'.
'native lifecycle installed'
