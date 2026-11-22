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
  id ]'.
'execution checkpoint installed'
