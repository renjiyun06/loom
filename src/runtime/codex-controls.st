"Preserve the local session, activity, and lifecycle interfaces for GT and desktop tools."
| host |
host := LMNativeCodexHost.
host compile: 'pendingCalls
 | listing running |
listing := Dictionary new.
running := transport activeCalls collect: [ :each | each at: ''requestId'' ].
(self filesIn: ''codex-requests'') do: [ :file |
 | id request key |
 id := file basenameWithoutExtension.
 ((running includes: id) not and: [
  (LoomIPC / ''codex-responses'' / file basename) exists not ]) ifTrue: [
  request := [ STONJSON fromString: file contents ] on: Error do: [ :error | Dictionary new ].
  ((request at: ''id'' ifAbsent: [ nil ]) = id and: [ (request at: ''action'' ifAbsent: [ nil ]) = ''ask'' ]) ifTrue: [
   key := request at: ''clientKey'' ifAbsent: [ nil ].
   key ifNotNil: [ (listing at: key ifAbsentPut: [ OrderedCollection new ]) add: id ] ] ] ].
^ listing'.
host compile: 'runningStateFor: record pending: pending
 | current queued |
current := transport activeForClient: (record at: ''clientKey'').
queued := (pending at: (record at: ''clientKey'') ifAbsent: [ #() ]) asArray.
record at: ''queued'' put: queued.
(current isNil or: [ current at: ''releasedAfterSilence'' ifAbsent: [ false ] ]) ifTrue: [
 ^ record at: ''call'' put: nil; at: ''runState'' put: (queued ifEmpty: [ ''idle'' ] ifNotEmpty: [ ''queued'' ]); yourself ].
^ record at: ''runState'' put: ''running'';
 at: ''call'' put: (Dictionary new at: ''requestId'' put: (current at: ''requestId''); at: ''threadId'' put: (current at: ''threadId'');
  at: ''turnId'' put: (current at: ''turnId'');
  at: ''canHandoff'' put: (transport canHandoffDuring: current);
  at: ''handoffRequested'' put: (current at: ''handoffRequested'' ifAbsent: [ false ]); yourself); yourself'.
host compile: 'control: request id: id
 | kind sessionId pending record |
(request at: ''instance'') = session ifFalse: [ self error: ''Loom restarted before handling this command'' ].
kind := request at: ''action''.
sessionId := request at: ''sessionId'' ifAbsent: [ nil ].
pending := self pendingCalls.
kind = ''list'' ifTrue: [ ^ registry sessions collect: [ :item | self runningStateFor: item pending: pending ] ].
kind = ''register'' ifTrue: [ ^ self runningStateFor: (registry register: sessionId) pending: pending ].
record := registry session: sessionId.
record ifNil: [ self error: ''Loom session does not exist: '', sessionId ].
record := self runningStateFor: record pending: pending.
kind = ''show'' ifTrue: [ ^ record ].
kind = ''recover'' ifTrue: [
 self isStopping ifTrue: [ self error: ''Loom 正在退出'' ].
 transport requestHandoffFor: (record at: ''clientKey'') request: (request at: ''requestId'' ifAbsent: [ nil ]).
 ^ self runningStateFor: (registry session: sessionId) pending: self pendingCalls ].
kind = ''rotate'' ifTrue: [
 (record at: ''runState'') = ''idle'' ifFalse: [ self error: ''Wait for pending calls to finish before switching the Codex session'' ].
 registry reset: (Dictionary new at: ''id'' put: id; at: ''action'' put: ''newConversation''; at: ''clientKey'' put: (record at: ''clientKey''); yourself).
 ^ self runningStateFor: (registry session: sessionId) pending: pending ].
self error: ''Unknown Loom session command'''.
host compile: 'pollSessions
 (self filesIn: ''session-requests'') do: [ :file |
 | id answer |
 id := file basenameWithoutExtension.
 answer := [
  Dictionary new at: ''ok'' put: true;
   at: ''value'' put: (self control: (STONJSON fromString: file contents) id: id); yourself
 ] on: Error do: [ :error | self failed: error messageText request: id ].
 LMPlatformTools writeJSON: answer to: LoomIPC / ''session-responses'' / file basename.
 file ensureDelete ]'.
host compile: 'runCheckpoints
 [ self isCurrent ] whileTrue: [
 (Smalltalk globals at: #LoomExecutionCheckpoint ifAbsent: [ nil ]) ifNotNil: [ :current |
  (current at: ''handled'' ifAbsent: [ false ]) ifFalse: [ self checkpoint: current ] ].
 (Delay forMilliseconds: 35) wait ]'.
host compile: 'checkpoint: control
 | id receipt result deadline |
control at: ''handled'' put: true.
id := control at: ''id''.
receipt := LoomIPC / ''checkpoint-results'' / (id, ''.json'').
[
 receipt exists ifFalse: [ self scheduleSnapshot: id control: control ].
 deadline := DateAndTime now + 80 seconds.
 [ receipt exists or: [ (control includesKey: ''error'') or: [ self isCurrent not ] ] ] whileFalse: [
  DateAndTime now >= deadline ifTrue: [ self error: ''Execution checkpoint save timed out'' ].
  (Delay forMilliseconds: 35) wait ].
 self isCurrent ifFalse: [ ^ self ].
 (control includesKey: ''error'') ifFalse: [
  result := STONJSON fromString: receipt contents.
  (result at: ''ok'') ifTrue: [
   status at: ''image'' put: (ExperimentRoot resolve: (result at: ''image'')) fullName.
   self publishStatus: (status at: ''status'')
  ] ifFalse: [ control at: ''error'' put: (result at: ''error'') ] ]
] on: Error do: [ :error | control at: ''error'' put: error messageText ].
(control at: ''gate'') signal'.
host compile: 'scheduleSnapshot: id control: control
 | snapshot universe |
snapshot := [
 [ LMExecution nativeStateCritical: [
    | operation |
    LoomMailboxProcess suspend.
    [
     operation := LMExecution nativeSnapshotDuring: [
      Smalltalk imageFile fullName = (status at: ''workingImage'')
       ifTrue: [ Smalltalk snapshot: true andQuit: false ]
       ifFalse: [ Smalltalk saveAs: (ExperimentRoot / ''state'' / ''runtime'' / ''working'' / ''main'') fullName ] ].
    ] ensure: [ (self isCurrent and: [ LoomMailboxProcess isSuspended ]) ifTrue: [ LoomMailboxProcess resume ] ].
    (self isCurrent and: [ operation isImageStarting not ]) ifTrue: [
     LMPlatformTools writeJSON: Dictionary new to: LoomIPC / ''checkpoint-saved'' / (id, ''.json'') ]
   ]
 ] on: Error do: [ :error | control at: ''error'' put: error messageText ] ].
universe := gui ifTrue: [ BlParallelUniverse forHost: BlWinitHost ] ifFalse: [ nil ].
(universe notNil and: [ universe hasUIProcess ])
 ifTrue: [ universe postpone: snapshot ] ifFalse: [ snapshot fork ]'.
host compile: 'pollNativeActions
 (nativeWorker notNil and: [ nativeWorker isTerminated not ]) ifTrue: [ ^ self ].
(self filesIn: ''native-actions'') do: [ :file |
 | id receipt request |
 id := file basenameWithoutExtension.
 receipt := LoomIPC / ''native-results'' / file basename.
 receipt exists ifFalse: [
  request := [ STONJSON fromString: file contents ] on: Error do: [ :error | Dictionary new ].
  ((request at: ''session'' ifAbsent: [ nil ]) = session and: [ (request at: ''id'' ifAbsent: [ nil ]) = id ])
   ifFalse: [ LMPlatformTools writeJSON: (self failed: ''Previous or invalid native lifecycle request'' request: id) to: receipt ]
   ifTrue: [
    (request at: ''quit'') ifTrue: [ self scheduleShutdownSaving: (request at: ''save'') native: id ]
     ifFalse: [ self scheduleNativeSave: id ].
    ^ self ] ] ]'.
host compile: 'scheduleNativeSave: id
 nativeWorker := [
 | result |
 result := [
  Dictionary new at: ''ok'' put: true; at: ''saved'' put: true; at: ''checkpoint'' put: LMExecution checkpoint;
   at: ''restored'' put: false; yourself
 ] on: Error do: [ :error | self failed: error messageText request: id ].
 LMPlatformTools writeJSON: result to: LoomIPC / ''native-results'' / (id, ''.json'').
 LMExecution completeNativeAction: id result: result
] fork'.
host compile: 'scheduleShutdownSaving: save native: id
 stopping = true ifTrue: [ ^ self ].
stopping := true.
nativeWorker := [ [ self shutdownSaving: save native: id ] on: Error do: [ :error | self fatal: error messageText ] ] fork'.
host compile: 'shutdownSaving: save native: id
 | result deadline checkpoint |
self publishStatus: ''stopping''.
deadline := DateAndTime now + 8 seconds.
[ self hasRunningRequests and: [ DateAndTime now < deadline ] ] whileTrue: [ (Delay forMilliseconds: 40) wait ].
self hasRunningRequests ifTrue: [ transport stop. worker terminate. self retireRequestWorkers ].
(Smalltalk globals at: #LoomApplications ifAbsent: [ nil ]) ifNotNil: [ :apps |
 [ apps prepareShutdown ] on: Error do: [ :error | Smalltalk globals at: #LoomApplicationLoadError put: error messageText ] ].
checkpoint := save ifTrue: [ LMExecution checkpoint ] ifFalse: [ nil ].
self isCurrent ifFalse: [ ^ self ].
result := Dictionary new at: ''ok'' put: true; at: ''saved'' put: save; at: ''checkpoint'' put: checkpoint; yourself.
id ifNotNil: [
 LMPlatformTools writeJSON: result to: LoomIPC / ''native-results'' / (id, ''.json'').
 LMExecution completeNativeAction: id result: result ].
transport stop.
(LoomIPC / ''stop.json'') ensureDelete.
status at: ''saved'' put: save; at: ''stoppedAt'' put: registry now.
self publishStatus: ''stopped''.
Smalltalk exitSuccess'.
'GT Codex control installed'
