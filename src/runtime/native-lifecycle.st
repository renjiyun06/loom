"Unify native Save/Quit with committed recovery checkpoints."
| imageClass |
imageClass := Smalltalk class.
(Smalltalk globals includesKey: #BridgeOriginalSnapshotMethod) ifFalse: [
 Smalltalk globals at: #BridgeOriginalSnapshotMethod put: (imageClass >> #snapshot:andQuit:) ].
(Smalltalk globals includesKey: #BridgeNativeActionMutex) ifFalse: [
 Smalltalk globals at: #BridgeNativeActionMutex put: Mutex new ].
LMExecution class compile: 'nativeSnapshotDuring: block
 | previous |
 previous := Smalltalk globals at: #BridgeInternalSnapshotProcess ifAbsent: [ nil ].
 Smalltalk globals at: #BridgeInternalSnapshotProcess put: Processor activeProcess.
 ^ block ensure: [
  previous ifNil: [ Smalltalk globals removeKey: #BridgeInternalSnapshotProcess ifAbsent: [] ]
   ifNotNil: [ Smalltalk globals at: #BridgeInternalSnapshotProcess put: previous ] ]'.
LMExecution class compile: 'managedSnapshot: save andQuit: quit
 | id gate state request operation |
 (save or: [ quit ]) ifFalse: [ ^ false ].
 Processor activeProcess == BridgeMailboxProcess ifTrue: [
  self error: ''Run native Save/Quit in a separate runtime Process'' ].
 ^ BridgeNativeActionMutex critical: [
  id := UUID new asString. gate := Semaphore new.
  state := Dictionary new at: ''id'' put: id; at: ''gate'' put: gate;
   at: ''session'' put: BridgeRuntimeSessionId; at: ''save'' put: save; at: ''quit'' put: quit; yourself.
  Smalltalk globals at: #BridgeNativeAction put: state.
  [
   request := BridgeIPC / ''native-actions'' / (id , ''.tmp'').
   request writeStreamDo: [ :stream |
    stream nextPutAll: (STONJSON toString: (Dictionary new at: ''id'' put: id;
     at: ''session'' put: BridgeRuntimeSessionId; at: ''save'' put: save; at: ''quit'' put: quit; yourself)) ].
   request renameTo: id , ''.json''.
   gate wait.
   (state at: ''ok'' ifAbsent: [ false ]) ifFalse: [
    self error: (state at: ''error'' ifAbsent: [ ''Native save failed'' ]) ].
   operation := SnapshotOperation save: save andQuit: quit withSessionManager: SessionManager default.
   operation instVarNamed: ''isImageStarting'' put: (state at: ''restored'' ifAbsent: [ false ]).
   operation
  ] ensure: [ Smalltalk globals removeKey: #BridgeNativeAction ifAbsent: [] ] ]'.
LMExecution class compile: 'completeNativeAction: id result: result
 | state |
 state := Smalltalk globals at: #BridgeNativeAction ifAbsent: [ ^ false ].
 (state at: ''id'') = id ifFalse: [ ^ false ].
 result keysAndValuesDo: [ :key :value | state at: key put: value ].
 (state at: ''gate'') signal.
 ^ true'.
LMExecution class compile: 'restoreNativeAction
 | state |
 state := Smalltalk globals at: #BridgeNativeAction ifAbsent: [ ^ false ].
 (state at: ''session'') = BridgeRuntimeSessionId ifTrue: [ ^ false ].
 "A committed image contains the waiting caller, never an instruction to quit again."
 state at: ''ok'' put: true; at: ''restored'' put: true.
 (state at: ''gate'') signal.
 ^ true'.
imageClass compile: 'snapshot: save andQuit: quit
 (Smalltalk globals at: #BridgeInternalSnapshotProcess ifAbsent: [ nil ]) == Processor activeProcess
  ifTrue: [ ^ BridgeOriginalSnapshotMethod valueWithReceiver: self arguments: {save. quit} ].
 ^ LMExecution managedSnapshot: save andQuit: quit'.
"GT requests are already asynchronous. Keep its pulse loop free while the bridge saves."
BlParallelUniverse compile: 'snapshot: save andQuit: quit
 ^ [ Smalltalk snapshot: save andQuit: quit ] fork'.
'native lifecycle installed'
