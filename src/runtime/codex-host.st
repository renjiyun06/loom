"The GT runtime owns Codex ingress, durable results, and generic lifecycle."
| host previous |
previous := Smalltalk globals at: #LMNativeCodexHost ifAbsent: [ nil ].
(previous notNil and: [ previous instVarNames includes: 'views' ]) ifTrue: [
 #(start pollActivity acceptView: publishView:channel:) do: [ :selector |
  (previous includesSelector: selector) ifTrue: [ previous removeSelector: selector ] ] ].
host := (Object << #LMNativeCodexHost slots: #(#session #epoch #gui #options #status #settings #registry #transport #worker #monitor #checkpointWorker #nativeWorker #stopping); package: 'Loom-Codex') install.
host compile: 'start
 | config pathConfig default identity state |
session := LoomRuntimeSessionId.
epoch := OSEnvironment current at: ''LOOM_RUNTIME_EPOCH''.
config := STONJSON fromString: (ExperimentRoot / ''config'' / ''runtime.json'') contents.
pathConfig := config at: ''paths''.
options := Dictionary new.
pathConfig keysAndValuesDo: [ :key :value | options at: key put: (ExperimentRoot resolve: value) ].
gui := config at: ''gui'' ifAbsent: [ false ].
Smalltalk globals at: #LoomGuiEnabled put: gui.
#(''codex-requests'' ''codex-responses'' ''session-requests'' ''session-responses'' ''native-actions'' ''native-results'')
 do: [ :name | (LoomIPC / name) ensureCreateDirectory ].
state := STONJSON fromString: (LoomIPC / ''runtime-status.json'') contents.
status := state copy at: ''objectInvocation'' put: true; at: ''sessionControl'' put: session;
 at: ''runtimeDirectory'' put: LoomIPC fullName; at: ''cwd'' put: (options at: ''workspace'') fullName;
 at: ''workingImage'' put: Smalltalk imageFile fullName; at: ''transport'' put: ''GT / Codex App Server stdio''; yourself.
registry := LMNativeSessionRegistry new initializeAt: ExperimentRoot / ''state'' / ''sessions''; yourself.
default := registry initializeDefault: LoomCodex threadId.
LoomCodex clientKey: ''default''; synchronizeThreadId: (default at: ''threadId'').
registry recoverActivities.
registry recoveredCalls do: [ :entry | self reply: entry value for: entry key ].
transport := LMNativeCodexTransport new.
identity := transport start: options registry: registry.
settings := LMNativeCodexSettings new initializeAt: (ExperimentRoot / ''config'' / ''codex.json''); yourself.
settings models: ([ transport modelCatalog ] on: Error do: [ :error | #() ]).
status at: ''codexPid'' put: transport pid; at: ''appServer'' put: (identity at: ''userAgent'' ifAbsent: [ nil ]).
LMPlatformTools writeJSON: settings options to: LoomIPC / ''codex-options.json''.
self publishStatus: ''ready''.
self restoreWaitingCallers.
worker := [ self runRequests ] fork.
worker name: ''Loom Codex request queue''.
monitor := [ self runControls ] fork.
monitor name: ''Loom Codex controls''.
checkpointWorker := [ self runCheckpoints ] fork.
checkpointWorker name: ''Loom execution checkpoints''.
[
 [ LoomApplications start ]
  on: Error do: [ :error |
   Smalltalk globals at: #LoomApplicationLoadError put: error messageText.
   Smalltalk globals at: #LoomApplicationLoadTrace put: (error signalerContext stack collect: #printString) ]
] fork.'.
host compile: 'restoreWaitingCallers
 (Smalltalk globals at: #LoomExecutionCheckpoint ifAbsent: [ nil ])
  ifNotNil: [ :state | (state at: ''gate'') signal ].
LMExecution restoreNativeAction'.
host compile: 'publishStatus: phase
 status at: ''status'' put: phase.
LMPlatformTools writeJSON: status to: LoomIPC / ''runtime-status.json'''.
host compile: 'isCurrent
 ^ session = LoomRuntimeSessionId and: [
  epoch = (OSEnvironment current at: ''LOOM_RUNTIME_EPOCH'' ifAbsent: [ nil ]) ]'.
host compile: 'isToolProcess
 ^ transport notNil and: [ transport isToolProcess ]'.
host compile: 'registry ^ registry'.
host compile: 'uuid: value
 ^ value isString and: [ value matchesRegex: ''[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}'' ]'.
host compile: 'filesIn: name
 ^ ((LoomIPC / name) files select: [ :file |
 file extension = ''json'' and: [ self uuid: file basenameWithoutExtension ] ]) sorted'.
host compile: 'reply: result for: id
 LMPlatformTools writeJSON: result to: (LoomIPC / ''codex-responses'' / (id, ''.json''))'.
host compile: 'failed: message request: id
 ^ Dictionary new at: ''ok'' put: false; at: ''id'' put: id; at: ''error'' put: message; yourself'.
host compile: 'validateRequest: request id: id
 | action key prompt expected thread |
action := request at: ''action'' ifAbsent: [ nil ].
key := request at: ''clientKey'' ifAbsent: [ nil ].
prompt := request at: ''prompt'' ifAbsent: [ nil ].
expected := request at: ''requiredThreadId'' ifAbsent: [ nil ].
thread := request at: ''threadId'' ifAbsent: [ nil ].
((request at: ''id'' ifAbsent: [ nil ]) = id and: [
 (#(''ask'' ''newConversation'' ''status'' ''configure'') includes: action) and: [
 prompt isString and: [
 (action ~= ''ask'' or: [ prompt trimBoth isNotEmpty ]) and: [
 ((request includesKey: ''objectInvocation'') not or: [
  (request at: ''objectInvocation'') = true and: [ action = ''ask'' ] ]) and: [
 (expected isNil or: [ action = ''ask'' and: [ expected isString and: [ expected isNotEmpty ] ] ]) and: [
 thread isNil or: [ thread isString ] ] ] ] ] ] ])
 ifFalse: [ self error: ''Invalid Codex request'' ].
registry validate: key max: 128'.
host compile: 'performRequestFile: file
 | id result |
id := file basenameWithoutExtension.
(LoomIPC / ''codex-responses'' / file basename) exists ifTrue: [ ^ self ].
result := [
 | request |
 request := STONJSON fromString: file contents.
 self validateRequest: request id: id.
 self performRequest: request
] on: Error do: [ :error | self failed: error messageText request: id ].
self isCurrent ifTrue: [ self reply: result for: id ]'.
host compile: 'performRequest: request
 | id action key previous result |
id := request at: ''id''.
action := request at: ''action''.
key := request at: ''clientKey''.
action = ''configure'' ifTrue: [
 LMPlatformTools writeJSON: (settings save: (STONJSON fromString: (request at: ''prompt''))) to: LoomIPC / ''codex-options.json''.
 ^ Dictionary new at: ''id'' put: id; at: ''ok'' put: true; at: ''text'' put: ''''; yourself ].
action = ''newConversation'' ifTrue: [ ^ registry reset: request ].
action = ''status'' ifTrue: [
 ^ (registry ensureClient: key) at: ''id'' put: id; at: ''ok'' put: true; at: ''text'' put: ''''; yourself ].
previous := registry callResult: id.
previous ifNotNil: [ ^ previous ].
registry beginCall: request.
result := [ transport ask: request settings: settings turnParams workspace: (options at: ''workspace'') fullName ]
 on: Error do: [ :error | self failed: error messageText request: id ].
self isCurrent ifTrue: [ registry completeCall: id result: result ].
^ result'.
host compile: 'runRequests
 [
 [ self isCurrent and: [ stopping ~= true ] ] whileTrue: [
  (self filesIn: ''codex-requests'') do: [ :file |
   (self isCurrent and: [ stopping ~= true ]) ifTrue: [ self performRequestFile: file ] ].
  (Delay forMilliseconds: 50) wait ]
] on: Error do: [ :error | self fatal: error messageText ]'.
host compile: 'runControls
 [
 [ self isCurrent ] whileTrue: [
  | active |
  (transport failure notNil and: [ stopping ~= true ]) ifTrue: [ self fatal: transport failure ].
  (LoomIPC / ''stop.json'') exists ifTrue: [ self scheduleShutdownSaving: true native: nil ].
  active := transport active.
  active ifNotNil: [
   (stopping = true
    and: [ (active at: ''turnId'') notNil and: [ (active at: ''interruptionSent'' ifAbsent: [ false ]) not ] ]) ifTrue: [
     [ [ transport interrupt ] on: Error do: [ :ignored | nil ] ] fork ] ].
  #(pollSessions pollNativeActions) do: [ :selector |
   [ self perform: selector ] on: Error do: [ :error |
    Smalltalk globals at: #LoomNativeControlError put: error messageText ] ].
  (Delay forMilliseconds: 80) wait ]
] on: Error do: [ :error | self fatal: error messageText ]'.
host compile: 'fatal: message
 self isCurrent ifFalse: [ ^ self ].
status ifNotNil: [ status at: ''error'' put: message. self publishStatus: ''failed'' ].
Smalltalk exitFailure'.
host compile: 'retire
 worker ifNotNil: #terminate.
monitor ifNotNil: #terminate.
checkpointWorker ifNotNil: #terminate.
nativeWorker ifNotNil: #terminate.
transport ifNotNil: #retire'.
'GT Codex host installed'
