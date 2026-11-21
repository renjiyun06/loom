| execution |
execution := (Object << #LMExecution slots: {}; package: 'Loom-Execution') install.
(Smalltalk globals includesKey: #BridgeCheckpointMutex) ifFalse: [ Smalltalk globals at: #BridgeCheckpointMutex put: Mutex new ].
execution class compile: 'checkpoint
 | id gate request checkpoint |
 Processor activeProcess == BridgeMailboxProcess ifTrue: [ self error: ''Run checkpointed work in a separate runtime Process'' ].
 ^ BridgeCheckpointMutex critical: [
  id := UUID new asString. gate := Semaphore new.
  checkpoint := Dictionary new at: ''id'' put: id; at: ''gate'' put: gate; yourself.
  Smalltalk globals at: #BridgeExecutionCheckpoint put: checkpoint.
  request := BridgeIPC / ''checkpoint-requests'' / (id , ''.tmp'').
  request writeStreamDo: [ :s | s nextPutAll: (STONJSON toString: (Dictionary new at: ''id'' put: id; yourself)) ].
  request renameTo: id , ''.json''.
  gate wait.
  Smalltalk globals removeKey: #BridgeExecutionCheckpoint ifAbsent: [].
  (checkpoint includesKey: ''error'') ifTrue: [ self error: (checkpoint at: ''error'') ].
  id ]'.
'execution checkpoint installed'
