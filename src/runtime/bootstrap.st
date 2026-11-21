"Rebind transport while preserving application objects in the image."
| root ipc previous heartbeatPrevious inbox outbox command code result response |
previous := Smalltalk globals at: #BridgeMailboxProcess ifAbsent: [ nil ].
(previous notNil and: [ previous ~~ Processor activeProcess ]) ifTrue: [ previous terminate ].
root := FileLocator workingDirectory.
ipc := root / 'ipc'.
inbox := ipc / 'mailbox'. inbox ensureCreateDirectory.
outbox := ipc / 'results'. outbox ensureCreateDirectory.
Smalltalk globals at: #ExperimentRoot put: root.
Smalltalk globals at: #BridgeIPC put: ipc.

Smalltalk globals at: #ExperimentRunning put: true.
Smalltalk globals at: #BridgeRuntimeSessionId put: UUID new asString.
heartbeatPrevious := Smalltalk globals at: #BridgeHeartbeatProcess ifAbsent: [ nil ].
heartbeatPrevious ifNotNil: [ heartbeatPrevious terminate ].
Smalltalk globals at: #BridgeHeartbeatProcess put: ([
 [ true ] whileTrue: [
  (ipc / 'runtime-heartbeat.txt') writeStreamDo: [ :s | s nextPutAll: DateAndTime now asString ].
  (Delay forSeconds: 1) wait ]
] forkAt: Processor userInterruptPriority).
(ipc / 'ready.json') writeStreamDo: [ :s |
 s nextPutAll: (STONJSON toString: (Dictionary new
  at: 'version' put: SystemVersion current asString;
  at: 'session' put: (Smalltalk globals at: #BridgeRuntimeSessionId);
  at: 'image' put: Smalltalk imageFile fullName;
  at: 'root' put: root fullName;
  yourself)) ].
Smalltalk globals at: #BridgeMailboxProcess put: ([ [ Smalltalk globals at: #ExperimentRunning ] whileTrue: [
 (inbox files select: [ :file | file extension = 'st' ]) sorted do: [ :file |
  command := file basenameWithoutExtension. code := file contents.
  [ result := Smalltalk compiler evaluate: code.
   response := Dictionary new at: 'ok' put: true; at: 'value' put: result; yourself.
   STONJSON toString: response
  ] on: Error do: [ :error |
   response := Dictionary new
    at: 'ok' put: false; at: 'error' put: error class name;
    at: 'message' put: error messageText;
    at: 'stack' put: (String streamContents: [ :s | s nextPutAll: error signalerContext printString ]);
    yourself ].
  (outbox / (command , '.json')) writeStreamDo: [ :s | s nextPutAll: (STONJSON toString: response) ].
  file delete ].
 (Delay forMilliseconds: 30) wait ].
] fork).
'Runtime mailbox started'

