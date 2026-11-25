"Speak Codex App Server JSON-RPC from GT; native process handles are scoped to this VM."
| transport |
transport := (Object << #LMNativeCodexTransport slots: #(#child #reader #pending #loaded #models #toolProcesses #writeMutex #serial #session #epoch #registry #failure #active #usage); package: 'Loom-Codex') install.
transport compile: 'start: options registry: aRegistry
 | builder cwd temp logs identity |
registry := aRegistry.
self initializeUsage.
session := LoomRuntimeSessionId.
epoch := OSEnvironment current at: ''LOOM_RUNTIME_EPOCH''.
pending := Dictionary new.
loaded := Set new.
models := Dictionary new.
toolProcesses := IdentitySet new.
writeMutex := Mutex new.
serial := 0.
cwd := options at: ''workspace''.
temp := options at: ''temporary''.
logs := options at: ''logs''.
#(''workspace'' ''temporary'' ''logs'') do: [ :name | (options at: name) ensureCreateDirectory ].
builder := (GtExternalProcessBuilder new: (options at: ''codexExecutable'') fullName)
 arguments: #(''app-server'' ''--stdio''); workingDirectory: cwd fullName;
 env: ''TMP'' value: temp fullName; env: ''TEMP'' value: temp fullName;
 pipeStdin; pipeStdout; yourself.
builder stderr: (GtExternalProcessFileStdio new fileReference: (logs / ''codex.stderr.log'') asAbsolute;
 create: true; append: true; yourself).
child := builder spawn.
child terminateOnShutdown.
reader := [ self readMessages ] fork.
reader name: ''Loom Codex JSON-RPC reader''.
identity := self rpc: ''initialize'' params: (STONJSON fromString:
 ''{"clientInfo":{"name":"loom","title":"Loom","version":"0.1.0"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}'').
self send: (Dictionary new at: ''method'' put: ''initialized''; yourself).
^ identity'.
transport compile: 'initializeUsage
 usage := LMCodexUsage new initializeWith: self registry: registry; yourself'.
transport compile: 'usage ^ usage'.
transport compile: 'modelCatalog
 | params page cursor models deadline |
 params := Dictionary new at: ''limit'' put: 100; yourself.
 models := OrderedCollection new.
 deadline := DateAndTime now + 8 seconds.
 [
  page := self rpc: ''model/list'' params: params timeout: ((deadline - DateAndTime now) asSeconds max: 1).
  models addAll: (page at: ''data'').
  cursor := page at: ''nextCursor'' ifAbsent: [ nil ].
  cursor isNil or: [ DateAndTime now >= deadline ]
 ] whileFalse: [ params at: ''cursor'' put: cursor ].
 ^ models asArray'.
transport compile: 'pid
 ^ child id'.
transport compile: 'active
 ^ active'.
transport compile: 'failure
 ^ failure'.
transport compile: 'isCurrent
 ^ session = LoomRuntimeSessionId and: [
  epoch = (OSEnvironment current at: ''LOOM_RUNTIME_EPOCH'' ifAbsent: [ nil ]) ]'.
transport compile: 'isToolProcess
 ^ toolProcesses includes: Processor activeProcess'.
transport compile: 'checkAlive
 self isCurrent ifFalse: [ self error: ''Previous Codex transport was stopped'' ].
failure ifNotNil: [ self error: failure ]'.
transport compile: 'send: message
 self checkAlive.
writeMutex critical: [ child stdin nextPutAll: (STONJSON toString: message), String lf ]'.
transport compile: 'rpc: method params: arguments
 ^ self rpc: method params: arguments timeout: 30'.
transport compile: 'rpc: method params: arguments timeout: seconds
 | id deadline result |
writeMutex critical: [ serial := serial + 1. id := serial. pending at: id put: nil ].
method = ''turn/start'' ifTrue: [
 active at: ''startRpcId'' put: id; at: ''earlyTurnEvents'' put: OrderedCollection new ].
[
 self send: (Dictionary new at: ''id'' put: id; at: ''method'' put: method; at: ''params'' put: arguments; yourself).
 deadline := DateAndTime now + (Duration seconds: seconds).
 [ (result := pending at: id) isNil ] whileTrue: [
  self checkAlive.
  DateAndTime now >= deadline ifTrue: [ self error: ''App Server timeout: '', method ].
  (Delay forMilliseconds: 20) wait ].
 result at: ''error'' ifPresent: [ :error |
  self error: ((error at: ''message'' ifAbsent: [ ''App Server request failed'' ]) asString) ].
 ^ result at: ''result'' ifAbsent: [ nil ]
] ensure: [ pending removeKey: id ifAbsent: [ ] ]'.
transport compile: 'readMessages
 | stream bytes offset chunk |
[
 stream := child asynchronousStdout.
 bytes := ByteArray new.
 [ self isCurrent and: [ failure isNil ] ] whileTrue: [
  chunk := stream pollBytes.
  bytes := bytes, chunk.
  [ offset := bytes indexOf: 10. offset > 0 ] whileTrue: [
   | line |
   line := (bytes first: offset - 1) utf8Decoded trimBoth.
   bytes := bytes allButFirst: offset.
   line ifNotEmpty: [ self receive: (STONJSON fromString: line) ] ].
  (chunk isEmpty and: [ stream isEndOfStreamReached or: [ child isTerminated ] ]) ifTrue: [
   self error: ''Codex App Server exited'' ].
  (Delay forMilliseconds: 15) wait ]
] on: Error do: [ :error | failure := error messageText ]'.
transport compile: 'receiveRPC: message id: id
 | current turn events |
 (id notNil and: [ pending includesKey: id ]) ifFalse: [ ^ self ].
 current := active.
 (current notNil and: [ (current at: ''startRpcId'' ifAbsent: [ nil ]) = id ]) ifTrue: [
  (message at: ''result'' ifAbsent: [ nil ]) ifNotNil: [ :response |
   turn := response at: ''turn''.
   current at: ''turnId'' put: (turn at: ''id'').
   self noteTurnProgress: ''轮次已开始'' at: Time millisecondClockValue during: current.
   events := current removeKey: ''earlyTurnEvents''.
   events do: [ :event | self receive: event ] ] ].
 pending at: id put: message'.
transport compile: 'receive: message
 | id method params current turnId |
id := message at: ''id'' ifAbsent: [ nil ].
method := message at: ''method'' ifAbsent: [ nil ].
method ifNil: [ ^ self receiveRPC: message id: id ].
params := message at: ''params'' ifAbsent: [ Dictionary new ].
current := active.
turnId := params at: ''turnId'' ifAbsent: [ (params at: ''turn'' ifAbsent: [ Dictionary new ]) at: ''id'' ifAbsent: [ nil ] ].
(current notNil and: [ turnId notNil and: [ (current at: ''turnId'') isNil and: [
 (params at: ''threadId'' ifAbsent: [ nil ]) = (current at: ''threadId'') ] ] ]) ifTrue: [
 (current at: ''earlyTurnEvents'' ifAbsent: [ nil ]) ifNotNil: [ :events |
  events add: message.
  ^ self ] ].
usage ifNotNil: [
 [ method = ''thread/tokenUsage/updated'' ifTrue: [ usage acceptTokenUsage: params ].
   method = ''account/updated'' ifTrue: [ usage resetAccount ].
   method = ''account/rateLimits/updated'' ifTrue: [ usage refreshRates ]
 ] on: Error do: [ :ignored | nil ] ].
(current notNil and: [ (params at: ''threadId'' ifAbsent: [ nil ]) = (current at: ''threadId'') ]) ifTrue: [
 (turnId isNil or: [ turnId = (current at: ''turnId'') ]) ifTrue: [
  turnId ifNotNil: [ self observeTurnEvent: method params: params during: current ].
  registry acceptActivity: message call: (current at: ''requestId'').
  method = ''item/completed'' ifTrue: [
   | item |
   item := params at: ''item''.
   (item at: ''type'') = ''agentMessage'' ifTrue: [ (current at: ''messages'') at: (item at: ''id'') put: item ] ].
  (method = ''turn/completed'' and: [ turnId notNil ]) ifTrue: [
   current at: ''completed'' ifAbsentPut: [ params at: ''turn'' ] ] ] ].
id ifNotNil: [
 [
  [ self respond: id method: method params: params active: current ]
   on: Error do: [ :error |
    self isCurrent ifTrue: [
     self send: (Dictionary new at: ''id'' put: id; at: ''error'' put: (Dictionary new
      at: ''code'' put: -32603; at: ''message'' put: error messageText; yourself); yourself) ] ]
 ] fork ]'.
transport compile: 'respond: id method: method params: params active: current
 | task result content |
task := Processor activeProcess.
toolProcesses add: task.
[
 method = ''item/tool/call'' ifFalse: [
  ^ self send: (Dictionary new at: ''id'' put: id; at: ''error'' put: (Dictionary new
   at: ''code'' put: -32601; at: ''message'' put: ''Unsupported interactive request: '', method; yourself); yourself) ].
 result := [
  (self permitsTool: params during: current) ifFalse: [ self error: ''Tool is not available for this runtime invocation.'' ].
  self evaluateTool: (params at: ''arguments'') during: current
 ] on: Error do: [ :error |
  Dictionary new at: ''ok'' put: false; at: ''error'' put: error messageText; yourself ].
 self isCurrent ifFalse: [ ^ self ].
 (self permitsTool: params during: current) ifTrue: [
  params at: ''callId'' ifPresent: [ :callId |
   registry completeToolActivity: callId call: (current at: ''requestId'') result: result ] ].
 content := Dictionary new at: ''type'' put: ''inputText''; at: ''text'' put: (STONJSON toString: result); yourself.
 self send: (Dictionary new at: ''id'' put: id; at: ''result'' put: (Dictionary new
  at: ''success'' put: (result at: ''ok''); at: ''contentItems'' put: {content}; yourself); yourself)
] ensure: [ toolProcesses remove: task ifAbsent: [ ] ]'.
transport compile: 'turnProgressLockDuring: current
 ^ current at: ''turnProgressLock'' ifAbsentPut: [ Mutex new ]'.
transport compile: 'noteTurnProgress: stage at: tick during: current
 (self turnProgressLockDuring: current) critical: [
  (current at: ''turnProgressEnded'' ifAbsent: [ false ]) ifFalse: [
   current at: ''lastTurnProgress'' put: { tick. stage } ] ]'.
transport compile: 'observeTurnEvent: method params: params during: current
 | stage |
 method = ''turn/completed'' ifTrue: [
  ^ (self turnProgressLockDuring: current) critical: [ current at: ''turnProgressEnded'' put: true ] ].
 stage := self progressStageFor: method params: params during: current.
 stage ifNotNil: [ self noteTurnProgress: stage at: Time millisecondClockValue during: current ]'.
transport compile: 'progressStageFor: method params: params during: current
 | item id seen started type stage delta |
 (#(''item/started'' ''item/completed'') includes: method) ifTrue: [
  item := params at: ''item'' ifAbsent: [ ^ nil ].
  id := item at: ''id'' ifAbsent: [ ^ nil ].
  seen := current at: ''turnItemTransitions'' ifAbsentPut: [ Set new ].
  (seen includes: { method. id }) ifTrue: [ ^ nil ].
  seen add: { method. id }.
  started := method = ''item/started''.
  type := item at: ''type'' ifAbsent: [ nil ].
  (#(''commandExecution'' ''dynamicToolCall'' ''mcpToolCall'' ''webSearch'') includes: type) ifTrue: [
   ^ started ifTrue: [ ''工具活动已开始'' ] ifFalse: [ ''工具活动已结束'' ] ].
  ^ type caseOf: {
   [ ''reasoning'' ] -> [ started ifTrue: [ ''思考中'' ] ifFalse: [ ''思考已结束'' ] ].
   [ ''agentMessage'' ] -> [ started ifTrue: [ ''正在输出文字'' ] ifFalse: [ ''文字输出已结束'' ] ].
   [ ''plan'' ] -> [ ''计划更新'' ].
   [ ''contextCompaction'' ] -> [ started ifTrue: [ ''正在压缩上下文'' ] ifFalse: [ ''上下文压缩已结束'' ] ] }
   otherwise: [ started ifTrue: [ ''活动已开始'' ] ifFalse: [ ''活动已结束'' ] ] ].
 method = ''turn/plan/updated'' ifTrue: [ ^ ''计划更新'' ].
 stage := method caseOf: {
  [ ''item/reasoning/summaryTextDelta'' ] -> [ ''思考中'' ].
  [ ''item/reasoning/textDelta'' ] -> [ ''思考中'' ].
  [ ''item/agentMessage/delta'' ] -> [ ''正在输出文字'' ].
  [ ''item/plan/delta'' ] -> [ ''计划更新'' ] }
  otherwise: [ ^ nil ].
 delta := params at: ''delta'' ifAbsent: [ ^ nil ].
 ^ ((delta isString) and: [ delta notEmpty ]) ifTrue: [ stage ] ifFalse: [ nil ]'.
transport compile: 'recordTurnSilenceDuring: current at: tick
 | progress elapsed |
 progress := current at: ''lastTurnProgress'' ifAbsent: [ ^ self ].
 (current at: ''reportedTurnSilence'' ifAbsent: [ nil ]) == progress ifTrue: [ ^ self ].
 elapsed := Time milliseconds: tick since: progress first.
 elapsed < 1800000 ifTrue: [ ^ self ].
 (self turnProgressLockDuring: current) critical: [
  ((current at: ''lastTurnProgress'') == progress and: [
   (current at: ''turnProgressEnded'' ifAbsent: [ false ]) not ]) ifTrue: [
    current at: ''reportedTurnSilence'' put: progress.
    [ registry recordTurnSilence: current stage: progress second seconds: elapsed // 1000 ]
      on: Error do: [ :error | Smalltalk globals at: #LoomActivityWriteError put: error messageText ] ] ]'.
transport compile: 'permitsTool: params during: current
 ^ current notNil and: [ active == current and: [ (current at: ''turnId'') notNil and: [
 (params at: ''tool'' ifAbsent: [ nil ]) = ''runtime_eval'' and: [
 (params at: ''threadId'' ifAbsent: [ nil ]) = (current at: ''threadId'') and: [
 | turn |
 turn := params at: ''turnId'' ifAbsent: [ nil ].
 turn isNil or: [ turn = (current at: ''turnId'') ] ] ] ] ] ]'.
transport compile: 'evaluateTool: raw during: current
 | arguments source value sessionId block invocation |
arguments := raw isString ifTrue: [ STONJSON fromString: raw ] ifFalse: [ raw ].
source := arguments at: ''code''.
source isString ifFalse: [ self error: ''Expected Smalltalk source in code'' ].
(current at: ''objectInvocation'')
 ifFalse: [ value := Smalltalk compiler evaluate: source ]
 ifTrue: [
  sessionId := registry sessionIdFor: (current at: ''clientKey'').
  block := Smalltalk compiler evaluate:
   (''[ :loomCaller :loomMessage :loomSessionId :loomReturn |'', String cr, source, String cr, '']'').
  invocation := LMInvocation pendingAt: (current at: ''requestId'').
  value := invocation evaluate: block sessionId: sessionId returning: [ :object |
   self saveObject: object from: invocation during: current ] ].
STONJSON toString: value.
^ Dictionary new at: ''ok'' put: true; at: ''value'' put: value; yourself'.
transport compile: 'objectReturnLockDuring: current
 ^ current at: ''objectReturnLock'' ifAbsentPut: [ Mutex new ]'.
transport compile: 'saveObject: object from: invocation during: current
 ^ (self objectReturnLockDuring: current) critical: [
  (active == current and: [ (current includesKey: ''completed'') not ])
   ifFalse: [ self error: ''This Codex turn has already ended'' ].
  invocation return: object.
  (current at: ''objectSaved'' ifAbsent: [ false ]) ifFalse: [
   [ LMExecution checkpoint ] on: Error do: [ :error |
    invocation discardUnsavedResult.
    error pass ].
   current at: ''objectSaved'' put: true.
   self noteTurnProgress: ''业务结果已保存，等待轮次结束'' at: Time millisecondClockValue during: current ].
  true ]'.
transport compile: 'threadOptions: workspace
 ^ Dictionary new at: ''cwd'' put: workspace; at: ''approvalPolicy'' put: ''never'';
 at: ''sandbox'' put: ''danger-full-access''; yourself'.
transport compile: 'dynamicTools
 ^ { STONJSON fromString: ''{"type":"function","name":"runtime_eval","description":"Evaluate Smalltalk in the live GT runtime that issued this call. Object calls bind loomCaller (Context), loomMessage (Message), loomSessionId (Loom session ID), and loomReturn (a one-argument block for returning a live object). Tool output must be JSON-serializable. See AGENTS.md. Do not synchronously invoke LoomCodex from this tool.","inputSchema":{"type":"object","properties":{"code":{"type":"string"}},"required":["code"],"additionalProperties":false}}'' }'.
transport compile: 'openThreadFor: current request: request in: workspace
 | key id binding thread options result |
key := current at: ''clientKey''.
id := current at: ''requestId''.
binding := registry ensureClient: key.
thread := binding at: ''threadId''.
current at: ''threadId'' put: thread.
request at: ''requiredThreadId'' ifPresent: [ :required |
 required = thread ifFalse: [ self error: ''底层 Codex 会话已切换，无法在原上下文中继续处理这条录音。'' ] ].
(binding at: ''state'') = ''creating'' ifTrue: [
 self error: ''Previous conversation creation has an uncertain outcome; refusing to create another conversation'' ].
options := self threadOptions: workspace.
thread ifNil: [
 registry beginCreate: key request: id.
 options at: ''dynamicTools'' put: self dynamicTools.
 result := self rpc: ''thread/start'' params: options.
 thread := (result at: ''thread'') at: ''id''.
 registry bind: thread key: key request: id.
 current at: ''threadId'' put: thread.
 loaded add: thread.
 models at: thread put: (result at: ''model'' ifAbsent: [ nil ]).
 self rpc: ''thread/name/set'' params: (Dictionary new at: ''threadId'' put: thread; at: ''name'' put: ''织境 Loom''; yourself).
 ^ thread ].
(loaded includes: thread) ifFalse: [
 options at: ''threadId'' put: thread; at: ''excludeTurns'' put: true.
 result := self rpc: ''thread/resume'' params: options.
 ((result at: ''thread'') at: ''id'') = thread ifFalse: [ self error: ''Codex resumed a different conversation; refusing to continue'' ].
 loaded add: thread.
 models at: thread put: (result at: ''model'' ifAbsent: [ nil ]) ].
^ thread'.
transport compile: 'ask: request settings: settings workspace: workspace
 | current result |
active ifNotNil: [ self error: ''Loom processes one model turn at a time'' ].
current := Dictionary new at: ''requestId'' put: (request at: ''id''); at: ''clientKey'' put: (request at: ''clientKey'');
 at: ''threadId'' put: nil; at: ''turnId'' put: nil; at: ''objectInvocation'' put: (request at: ''objectInvocation'' ifAbsent: [ false ]);
 at: ''messages'' put: OrderedDictionary new; at: ''startedAt'' put: registry now; yourself.
active := current.
[
 result := [
  | thread turn params |
  thread := self openThreadFor: current request: request in: workspace.
  params := settings copy at: ''threadId'' put: thread;
   at: ''input'' put: {Dictionary new at: ''type'' put: ''text''; at: ''text'' put: (request at: ''prompt'');
    at: ''text_elements'' put: #(); yourself}; yourself.
  self rpc: ''turn/start'' params: params.
  [ (turn := current at: ''completed'' ifAbsent: [ nil ]) isNil ] whileTrue: [
   self checkAlive.
   self recordTurnSilenceDuring: current at: Time millisecondClockValue.
   (Delay forMilliseconds: 25) wait ].
  self finishTurn: turn active: current model: (settings at: ''model'' ifAbsent: [ models at: thread ifAbsent: [ nil ] ])
 ] on: Error do: [ :error |
  [ self interrupt ] on: Error do: [ :ignored | nil ].
  (self receiptFrom: current) at: ''ok'' put: false; at: ''error'' put: error messageText; yourself ].
 ^ result
] ensure: [ active := nil ]'.
transport compile: 'receiptFrom: current
 ^ Dictionary new at: ''id'' put: (current at: ''requestId'');
 at: ''threadId'' put: (current at: ''threadId''); at: ''turnId'' put: (current at: ''turnId'');
 at: ''startedAt'' put: (current at: ''startedAt''); at: ''completedAt'' put: registry now; yourself'.
transport compile: 'finishTurn: turn active: current model: model
 | receipt status objectCall saved error rows finals text messages |
status := turn at: ''status''.
receipt := self receiptFrom: current.
receipt at: ''turnStatus'' put: status; at: ''model'' put: model.
objectCall := current at: ''objectInvocation''.
saved := objectCall and: [
 (self objectReturnLockDuring: current) critical: [ current at: ''objectSaved'' ifAbsent: [ false ] ] ].
status = ''completed'' ifFalse: [
 error := turn at: ''error'' ifAbsent: [ nil ].
 error ifNotNil: [ receipt at: ''turnError'' put: error ].
 receipt at: ''error'' put: (error
  ifNil: [ ''Codex turn '', status ]
  ifNotNil: [ error at: ''message'' ifAbsent: [ ''Codex turn '', status ] ]).
 (objectCall and: [ status = ''failed'' ]) ifFalse: [ ^ receipt at: ''ok'' put: false; yourself ].
 saved ifFalse: [ ^ receipt at: ''ok'' put: false; at: ''needsRecovery'' put: true; yourself ].
 receipt at: ''partialFailure'' put: true ].
(objectCall and: [ saved not ]) ifTrue: [
 ^ receipt at: ''ok'' put: false; at: ''needsRecovery'' put: true;
  at: ''error'' put: ''Codex completed without returning a GT object''; yourself ].
messages := current at: ''messages''.
(turn at: ''items'' ifAbsent: [ #() ]) do: [ :item |
 (item at: ''type'') = ''agentMessage'' ifTrue: [ messages at: (item at: ''id'') put: item ] ].
rows := messages values.
finals := rows select: [ :item | (item at: ''phase'' ifAbsent: [ nil ]) = ''final_answer'' ].
text := String lf join: ((finals ifEmpty: [ rows ]) collect: [ :item | item at: ''text'' ifAbsent: [ '''' ] ] thenSelect: #isNotEmpty).
(objectCall not and: [ text isEmpty ]) ifTrue: [
 ^ receipt at: ''ok'' put: false; at: ''error'' put: ''Completed Codex turn did not contain an assistant answer''; yourself ].
^ receipt at: ''ok'' put: true; at: ''text'' put: text; yourself'.
transport compile: 'interrupt
 | current turn |
current := active.
current ifNil: [ ^ self ].
turn := current at: ''turnId''.
turn ifNil: [ ^ self ].
(current at: ''interruptionSent'' ifAbsent: [ false ]) ifTrue: [ ^ self ].
current at: ''interruptionSent'' put: true.
^ self rpc: ''turn/interrupt'' params: (Dictionary new at: ''threadId'' put: (current at: ''threadId'');
 at: ''turnId'' put: turn; yourself) timeout: 5'.
transport compile: 'retire
 reader ifNotNil: #terminate.
toolProcesses copy do: #terminate'.
transport compile: 'stop
 reader ifNotNil: #terminate.
child ifNotNil: [ [ child stdin close ] on: Error do: [ :error | nil ].
 [ child terminate ] on: Error do: [ :error | nil ] ]'.
'GT Codex stdio installed'
