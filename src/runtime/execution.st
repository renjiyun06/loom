| execution |
execution := (Object << #LMExecution slots: {}; package: 'Loom-Execution') install.
(Smalltalk globals includesKey: #LoomCheckpointMutex) ifFalse: [ Smalltalk globals at: #LoomCheckpointMutex put: Mutex new ].
execution class compile: 'nativeStateCritical: operation
 ^ (Smalltalk globals at: #LoomNativeStateMutex ifAbsentPut: [ Mutex new ]) critical: operation'.
execution class compile: 'checkpoint
 | id gate request checkpoint |
 Processor activeProcess == LoomMailboxProcess ifTrue: [ self error: ''Run checkpointed work in a separate runtime Process'' ].
 ^ LoomCheckpointMutex critical: [
  id := UUID new asString. gate := Semaphore new.
  checkpoint := Dictionary new at: ''id'' put: id; at: ''gate'' put: gate; yourself.
  Smalltalk globals at: #LoomExecutionCheckpoint put: checkpoint.
  request := LoomIPC / ''checkpoint-requests'' / (id , ''.tmp'').
  request writeStreamDo: [ :s | s nextPutAll: (STONJSON toString: (Dictionary new at: ''id'' put: id; yourself)) ].
  request renameTo: id , ''.json''.
  gate wait.
  Smalltalk globals removeKey: #LoomExecutionCheckpoint ifAbsent: [].
  (checkpoint includesKey: ''error'') ifTrue: [ self error: (checkpoint at: ''error'') ].
  (Smalltalk globals at: #LMBusinessProcess ifAbsent: [ nil ]) ifNotNil: [ :binding |
   binding value ifNotNil: [ :run |
    | receipt saved |
    receipt := LoomIPC / ''checkpoint-results'' / (id, ''.json'').
    receipt exists ifTrue: [ saved := STONJSON fromString: receipt contents.
     ((saved at: ''ok'' ifAbsent: [ false ]) and: [ (saved at: ''id'' ifAbsent: [ nil ]) = id ]) ifTrue: [
      run savedCheckpoint: id at: (saved at: ''committedAt'' ifAbsent: [ nil ]) ] ] ] ].
  id ]'.
'execution checkpoint installed'
