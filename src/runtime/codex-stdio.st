"Speak Codex App Server JSON-RPC from GT; native process handles are scoped to this VM."
| transport |
transport := (Object << #LMNativeCodexTransport slots: #(#child #reader #pending #loaded #models #toolProcesses #writeMutex #serial #session #epoch #registry #failure #active #usage #turns #turnsLock); package: 'Loom-Codex') install.
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
transport compile: 'turnsLock
 ^ turnsLock ifNil: [ turnsLock := Mutex new ]'.
transport compile: 'activeCalls
 "A turn already on the stack during hot installation finishes using the old active slot."
 ^ self turnsLock critical: [
  | calls |
  calls := turns ifNil: [ #() ] ifNotNil: [ turns values asArray ].
  active ifNil: [ calls ] ifNotNil: [ calls copyWith: active ] ]'.
transport compile: 'activeForClient: key
 ^ self activeCalls detect: [ :each | (each at: ''clientKey'' ifAbsent: [ nil ]) = key ] ifNone: [ nil ]'.
transport compile: 'activeForThread: thread
 thread ifNil: [ ^ nil ].
 ^ self activeCalls detect: [ :each | (each at: ''threadId'') = thread ] ifNone: [ nil ]'.
transport compile: 'isActive: current
 ^ current notNil and: [ self activeCalls anySatisfy: [ :each | each == current ] ]'.
transport compile: 'registerTurn: current
 self turnsLock critical: [
  | key |
  key := current at: ''clientKey''.
  (self activeForClient: key) ifNotNil: [ self error: ''This session already has an active turn'' ].
  (turns ifNil: [ turns := Dictionary new ]) at: key put: current ]'.
transport compile: 'removeTurn: current
 self turnsLock critical: [
  active == current ifTrue: [ active := nil ].
  turns ifNotNil: [ | key |
   key := current at: ''clientKey''.
   (turns at: key ifAbsent: [ nil ]) == current ifTrue: [ turns removeKey: key ] ] ]'.
transport compile: 'executionAt: id
 self activeCalls do: [ :each |
  (each at: ''businessScope'' ifAbsent: [ nil ]) ifNotNil: [ :scope |
   (scope localExecutionAt: id) ifNotNil: [ :run | ^ run ] ] ].
 self error: ''Parent business execution is no longer active'''.
transport compile: 'businessScopeDuring: current
 ^ self turnsLock critical: [
  current at: ''businessScope'' ifAbsentPut: [
   LMBusinessScope new client: (current at: ''clientKey'') call: (current at: ''requestId'')
    parent: (current at: ''parentExecution'' ifAbsent: [ nil ])
    events: [ :call :fields |
     registry recordBusinessEvent: fields call: call.
     self noteTurnProgress: ''业务历程已推进'' at: Time millisecondClockValue during: current ];
    threadId: (current at: ''threadId''); yourself ] ]'.
transport compile: 'active
 ^ self activeCalls ifEmpty: [ nil ] ifNotEmpty: [ :calls | calls first ]'.
transport compile: 'failure
 ^ failure'.
transport compile: 'isCurrent
 ^ session = LoomRuntimeSessionId and: [
  epoch = (OSEnvironment current at: ''LOOM_RUNTIME_EPOCH'' ifAbsent: [ nil ]) ]'.
transport compile: 'isToolProcess
 ^ self turnsLock critical: [ toolProcesses includes: Processor activeProcess ]'.
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
self turnsLock critical: [ serial := serial + 1. id := serial. pending at: id put: nil ].
method = ''turn/start'' ifTrue: [
 (self activeForThread: (arguments at: ''threadId'')) at: ''startRpcId'' put: id; at: ''earlyTurnEvents'' put: OrderedCollection new ].
[
 self send: (Dictionary new at: ''id'' put: id; at: ''method'' put: method; at: ''params'' put: arguments; yourself).
 deadline := DateAndTime now + (Duration seconds: seconds).
 [ (result := self turnsLock critical: [ pending at: id ]) isNil ] whileTrue: [
  self checkAlive.
  DateAndTime now >= deadline ifTrue: [ self error: ''App Server timeout: '', method ].
  (Delay forMilliseconds: 20) wait ].
 result at: ''error'' ifPresent: [ :error |
  self error: ((error at: ''message'' ifAbsent: [ ''App Server request failed'' ]) asString) ].
 ^ result at: ''result'' ifAbsent: [ nil ]
] ensure: [ self turnsLock critical: [ pending removeKey: id ifAbsent: [ ] ] ]'.
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
 (id notNil and: [ self turnsLock critical: [ pending includesKey: id ] ]) ifFalse: [ ^ self ].
 current := self activeCalls detect: [ :each | (each at: ''startRpcId'' ifAbsent: [ nil ]) = id ] ifNone: [ nil ].
 current ifNotNil: [
  (message at: ''result'' ifAbsent: [ nil ]) ifNotNil: [ :response |
   turn := response at: ''turn''.
   current at: ''turnId'' put: (turn at: ''id'').
   self noteTurnProgress: ''轮次已开始'' at: Time millisecondClockValue during: current.
   events := current removeKey: ''earlyTurnEvents''.
   events do: [ :event | self receive: event ] ] ].
 self turnsLock critical: [ (pending includesKey: id) ifTrue: [ pending at: id put: message ] ]'.
transport compile: 'receive: message
 | id method params current turnId |
id := message at: ''id'' ifAbsent: [ nil ].
method := message at: ''method'' ifAbsent: [ nil ].
method ifNil: [ ^ self receiveRPC: message id: id ].
params := message at: ''params'' ifAbsent: [ Dictionary new ].
current := self activeForThread: (params at: ''threadId'' ifAbsent: [ nil ]).
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
  (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) ifFalse: [
   registry acceptActivity: message call: (current at: ''requestId'').
   method = ''item/completed'' ifTrue: [
    | item |
    item := params at: ''item''.
    (item at: ''type'') = ''agentMessage'' ifTrue: [ (current at: ''messages'') at: (item at: ''id'') put: item ] ] ].
  (method = ''turn/completed'' and: [ turnId notNil ]) ifTrue: [
   current at: ''completed'' ifAbsentPut: [ params at: ''turn'' ].
   (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) ifTrue: [
    self removeTurn: current.
    registry acceptActivity: message call: (current at: ''requestId'') ] ] ] ].
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
self turnsLock critical: [ toolProcesses add: task ].
[
 method = ''item/tool/call'' ifFalse: [
  ^ self send: (Dictionary new at: ''id'' put: id; at: ''error'' put: (Dictionary new
   at: ''code'' put: -32601; at: ''message'' put: ''Unsupported interactive request: '', method; yourself); yourself) ].
 result := [
  (self permitsTool: params during: current) ifFalse: [ self error: ''Tool is not available for this runtime invocation.'' ].
  LMBusinessToolCall value: (params at: ''callId'' ifAbsent: [ id ]) during: [
   self evaluateTool: (params at: ''arguments'') during: current ]
 ] on: Error do: [ :error |
  Dictionary new at: ''ok'' put: false; at: ''error'' put: error messageText; yourself ].
 self isCurrent ifFalse: [ ^ self ].
 (self permitsTool: params during: current) ifTrue: [
  params at: ''callId'' ifPresent: [ :callId |
   registry completeToolActivity: callId call: (current at: ''requestId'') result: result ] ].
 content := Dictionary new at: ''type'' put: ''inputText''; at: ''text'' put: (STONJSON toString: result); yourself.
 self send: (Dictionary new at: ''id'' put: id; at: ''result'' put: (Dictionary new
  at: ''success'' put: (result at: ''ok''); at: ''contentItems'' put: {content}; yourself); yourself)
] ensure: [ self turnsLock critical: [ toolProcesses remove: task ifAbsent: [ ] ] ]'.
transport compile: 'turnProgressLockDuring: current
 ^ current at: ''turnProgressLock'' ifAbsentPut: [ Mutex new ]'.
transport compile: 'noteTurnProgress: stage at: tick during: current
 (self turnProgressLockDuring: current) critical: [
  (current at: ''turnProgressEnded'' ifAbsent: [ false ]) ifFalse: [
   current at: ''lastTurnProgress'' put: { tick. stage }.
   current removeKey: ''quietSince'' ifAbsent: [ ].
   self endNetworkWaitDuring: current title: ''Codex 轮次恢复进展'' ] ]'.
transport compile: 'observeTurnEvent: method params: params during: current
 | stage |
 method = ''turn/completed'' ifTrue: [
  ^ (self turnProgressLockDuring: current) critical: [
   current at: ''turnProgressEnded'' put: true.
   self endNetworkWaitDuring: current title: ''Codex 轮次已结束'' ] ].
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
transport compile: 'elapsedMillisecondsAt: tick since: eventTick
 "A monitor sample may precede progress published by another process.
 Interpret the modular clock difference as signed so that a stale sample stays negative."
 | elapsed |
 elapsed := Time milliseconds: tick since: eventTick.
 ^ elapsed > (SmallInteger maxVal // 2)
  ifTrue: [ elapsed - SmallInteger maxVal ]
  ifFalse: [ elapsed ]'.
transport compile: 'recordTurnSilenceDuring: current at: tick
 | progress since elapsed release |
 (current at: ''businessScope'' ifAbsent: [ nil ]) ifNotNil: [ :scope | scope awaitsProgram ifTrue: [ ^ self ] ].
 (current at: ''networkProbe'' ifAbsent: [ nil ]) ifNotNil: [ :probe |
  ^ self pollNetwork: probe during: current at: tick ].
 progress := current at: ''lastTurnProgress'' ifAbsent: [ ^ self ].
 (current at: ''reportedTurnSilence'' ifAbsent: [ nil ]) == progress ifTrue: [ ^ self ].
 since := current at: ''quietSince'' ifAbsent: [ progress first ].
 elapsed := self elapsedMillisecondsAt: tick since: since.
 elapsed < 1800000 ifTrue: [ ^ self ].
 release := (self turnProgressLockDuring: current) critical: [
  ((current at: ''lastTurnProgress'') == progress and: [
   (current at: ''quietSince'' ifAbsent: [ progress first ]) = since and: [
   (current at: ''turnProgressEnded'' ifAbsent: [ false ]) not and: [
   (current at: ''reportedTurnSilence'' ifAbsent: [ nil ]) ~~ progress ] ] ]) ifTrue: [
    current at: ''reportedTurnSilence'' put: progress.
    release := current at: ''objectSaved'' ifAbsent: [ false ].
    [ registry recordTurnSilence: current stage: progress second seconds: elapsed // 1000 ]
      on: Error do: [ :error | Smalltalk globals at: #LoomActivityWriteError put: error messageText ].
    release ifTrue: [ current at: ''releasedAfterSilence'' put: true ] ifFalse: [
     (self canHandoffDuring: current) ifTrue: [
      | probe |
      probe := Dictionary new at: ''progress'' put: progress; yourself.
      current at: ''networkProbe'' put: probe.
      self startNetworkProbe: probe at: tick ] ].
    release ] ifFalse: [ false ] ].
 release ifTrue: [ self sendInterruptWithoutWaitingDuring: current ]'.
transport compile: 'startNetworkProbe: probe at: tick
 | answer |
 answer := Array new: 1.
 probe at: ''answer'' put: answer; at: ''startedAt'' put: tick.
 [ answer at: 1 put: ([ self probeNetworkReachable ] on: Error do: [ :error | false ]) ] fork'.
transport compile: 'probeNetworkReachable
 | curl status |
 curl := (OSEnvironment current at: ''SystemRoot'') asFileReference / ''System32'' / ''curl.exe''.
 status := LMPlatformTools run: curl arguments: #(''--disable'' ''--silent'' ''--fail'' ''--max-time'' ''5''
  ''--output'' ''NUL'' ''--write-out'' ''%{http_code}'' ''https://www.google.com/generate_204'') timeout: 6.
 ^ status trimBoth = ''204'''.
transport compile: 'pollNetwork: probe during: current at: tick
 | elapsed |
 (self turnProgressLockDuring: current) critical: [
  ((current at: ''networkProbe'' ifAbsent: [ nil ]) == probe and: [
    (current at: ''lastTurnProgress'') == (probe at: ''progress'') and: [
    (self canHandoffDuring: current) and: [ (current at: ''objectSaved'' ifAbsent: [ false ]) not ] ] ]) ifFalse: [ ^ self ].
  elapsed := self elapsedMillisecondsAt: tick since: (probe at: ''startedAt'').
  elapsed < 0 ifTrue: [ ^ self ].
  (probe at: ''answer'') first ifNotNil: [ :reachable |
   reachable ifTrue: [
    (probe includesKey: ''waitActivity'') ifTrue: [
     self endNetworkWaitDuring: current title: ''Google 探测已恢复，继续观察原轮次''.
     current at: ''quietSince'' put: tick.
     current removeKey: ''reportedTurnSilence'' ] ifFalse: [
     current removeKey: ''networkProbe''.
     self markHandoffDuring: current automatic: true.
     self sendInterruptWithoutWaitingDuring: current ]
   ] ifFalse: [
    (probe includesKey: ''waitActivity'') ifFalse: [
     probe at: ''waitActivity'' put: (''network-wait-'', UUID new asString).
     self recordNetworkWait: probe during: current title: ''Google 探测失败，正在等待网络恢复'' status: ''inProgress'' ].
    elapsed >= 15000 ifTrue: [
     self startNetworkProbe: probe at: tick ] ] ] ]'.
transport compile: 'endNetworkWaitDuring: current title: title
 (current removeKey: ''networkProbe'' ifAbsent: [ nil ]) ifNotNil: [ :probe |
  (probe includesKey: ''waitActivity'') ifTrue: [
   self recordNetworkWait: probe during: current title: title status: ''completed'' ] ]'.
transport compile: 'recordNetworkWait: probe during: current title: title status: status
 [ registry recordNetworkWait: (probe at: ''waitActivity'') during: current title: title status: status ]
  on: Error do: [ :error | Smalltalk globals at: #LoomActivityWriteError put: error messageText ]'.
transport compile: 'permitsTool: params during: current
 ^ current notNil and: [ (self isActive: current) and: [ (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) not and: [
 (current at: ''turnId'') notNil and: [
 (params at: ''tool'' ifAbsent: [ nil ]) = ''runtime_eval'' and: [
 (params at: ''threadId'' ifAbsent: [ nil ]) = (current at: ''threadId'') and: [
 | turn |
 turn := params at: ''turnId'' ifAbsent: [ nil ].
 turn isNil or: [ turn = (current at: ''turnId'') ] ] ] ] ] ] ]'.
transport compile: 'evaluateTool: raw during: current
 | arguments scope event |
arguments := raw isString ifTrue: [ STONJSON fromString: raw ] ifFalse: [ raw ].
scope := self businessScopeDuring: current.
event := scope evaluate: [ :run |
 | source compiler sessionId block invocation |
 source := arguments at: ''code''.
 source isString ifFalse: [ self error: ''Expected Smalltalk source in code'' ].
 compiler := Smalltalk compiler bindings: (Dictionary new at: #loomRun put: run; yourself); yourself.
 (current at: ''objectInvocation'')
  ifFalse: [ compiler evaluate: source ]
  ifTrue: [
   sessionId := registry sessionIdFor: (current at: ''clientKey'').
   block := compiler evaluate:
    (''[ :loomCaller :loomMessage :loomSessionId :loomReturn |'', String cr, source, String cr, '']'').
   invocation := LMInvocation pendingAt: (current at: ''requestId'').
   invocation evaluate: block sessionId: sessionId returning: [ :object |
    scope assertCanReturnFrom: run. self saveObject: object from: invocation during: current ] ] ].
(event at: ''kind'') = ''subrequest'' ifTrue: [ event at: ''value'' put: event copy ].
^ event at: ''ok'' put: (event at: ''kind'') ~= ''failed''; yourself'.
transport compile: 'objectReturnLockDuring: current
 ^ current at: ''objectReturnLock'' ifAbsentPut: [ Mutex new ]'.
transport compile: 'saveObject: object from: invocation during: current
 ^ (self objectReturnLockDuring: current) critical: [
  ((self isActive: current) and: [ (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) not and: [
   (current includesKey: ''completed'') not ] ])
   ifFalse: [ self error: ''This Codex turn has already ended'' ].
  invocation return: object.
  (current at: ''objectSaved'' ifAbsent: [ false ]) ifFalse: [
   [ LMExecution checkpoint ] on: Error do: [ :error |
    invocation discardUnsavedResult.
    error pass ].
   (self turnProgressLockDuring: current) critical: [
    self noteTurnProgress: ''业务结果已保存，等待轮次结束'' at: Time millisecondClockValue during: current.
    current at: ''objectSaved'' put: true ] ].
  true ]'.
transport compile: 'threadOptions: workspace
 ^ Dictionary new at: ''cwd'' put: workspace; at: ''approvalPolicy'' put: ''never'';
 at: ''sandbox'' put: ''danger-full-access''; yourself'.
transport compile: 'dynamicTools
 ^ { STONJSON fromString: ''{"type":"function","name":"runtime_eval","description":"Evaluate Smalltalk in the live GT runtime. Every evaluation runs in a managed process, including inspection and serialization. Inspect kind: completed returns value or valueClass, subrequest returns requestId. Use loomRun request: id to inspect and loomRun answer: id with: object to resume. Object calls bind loomCaller, loomMessage, loomSessionId and loomReturn. See AGENTS.md.","inputSchema":{"type":"object","properties":{"code":{"type":"string"}},"required":["code"],"additionalProperties":false}}'' }'.
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
 | current result previous |
"An early business result leaves the App Server turn busy until its terminal event."
[ (previous := self activeForClient: (request at: ''clientKey'')) notNil and: [ previous at: ''releasedAfterSilence'' ifAbsent: [ false ] ] ] whileTrue: [
 self checkAlive.
 (Delay forMilliseconds: 25) wait ].
current := Dictionary new at: ''requestId'' put: (request at: ''id''); at: ''clientKey'' put: (request at: ''clientKey'');
 at: ''threadId'' put: nil; at: ''turnId'' put: nil; at: ''objectInvocation'' put: (request at: ''objectInvocation'' ifAbsent: [ false ]);
 at: ''messages'' put: OrderedDictionary new; at: ''startedAt'' put: registry now; yourself.
request at: ''parentExecutionId'' ifPresent: [ :id | current at: ''parentExecution'' put: (self executionAt: id) ].
self registerTurn: current.
[
 result := [
  | thread turn params |
  thread := self openThreadFor: current request: request in: workspace.
  params := settings copy at: ''threadId'' put: thread;
   at: ''input'' put: {Dictionary new at: ''type'' put: ''text''; at: ''text'' put: (request at: ''prompt'');
    at: ''text_elements'' put: #(); yourself}; yourself.
  self rpc: ''turn/start'' params: params.
  [ (turn := current at: ''completed'' ifAbsent: [ nil ]) isNil and: [
   (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) not ] ] whileTrue: [
   self checkAlive.
   self recordTurnSilenceDuring: current at: Time millisecondClockValue.
   (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) ifFalse: [ (Delay forMilliseconds: 25) wait ] ].
  (current at: ''releasedAfterSilence'' ifAbsent: [ false ])
   ifTrue: [ self finishSilentTurn: current ]
   ifFalse: [ self finishTurn: turn active: current model: (settings at: ''model'' ifAbsent: [ models at: thread ifAbsent: [ nil ] ]) ]
 ] on: Error do: [ :error |
  [ self interruptDuring: current ] on: Error do: [ :ignored | nil ].
  (self receiptFrom: current) at: ''ok'' put: false; at: ''error'' put: error messageText; yourself ].
 ^ result
] ensure: [
 (current at: ''businessScope'' ifAbsent: [ nil ]) ifNotNil: #close.
 (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) ifFalse: [ self removeTurn: current ] ]'.
transport compile: 'finishSilentTurn: current
 | receipt |
 receipt := (self receiptFrom: current) at: ''ok'' put: true; at: ''text'' put: '''';
  at: ''partialFailure'' put: true; at: ''releasedAfterSilence'' put: true;
  at: ''error'' put: ''Codex 轮次静默，已保存的业务结果提前交回''; yourself.
 current at: ''interruptWriteError'' ifPresent: [ :reason |
  receipt at: ''error'' put: (''Codex 轮次静默，中断请求发送失败，已保存的业务结果提前交回。'', reason) ].
 ^ receipt'.
transport compile: 'receiptFrom: current
 ^ Dictionary new at: ''id'' put: (current at: ''requestId'');
 at: ''threadId'' put: (current at: ''threadId''); at: ''turnId'' put: (current at: ''turnId'');
 at: ''startedAt'' put: (current at: ''startedAt''); at: ''completedAt'' put: registry now; yourself'.
transport compile: 'finishTurn: turn active: current model: model
 | receipt status objectCall saved handoff error rows finals text messages |
status := turn at: ''status''.
receipt := self receiptFrom: current.
receipt at: ''turnStatus'' put: status; at: ''model'' put: model.
objectCall := current at: ''objectInvocation''.
handoff := current at: ''handoffRequested'' ifAbsent: [ false ].
handoff ifTrue: [ receipt at: ''handoffRequested'' put: true ].
saved := objectCall and: [
 (self objectReturnLockDuring: current) critical: [ current at: ''objectSaved'' ifAbsent: [ false ] ] ].
status = ''completed'' ifFalse: [
 error := turn at: ''error'' ifAbsent: [ nil ].
 error ifNotNil: [ receipt at: ''turnError'' put: error ].
 receipt at: ''error'' put: (error
  ifNil: [ ''Codex turn '', status ]
  ifNotNil: [ error at: ''message'' ifAbsent: [ ''Codex turn '', status ] ]).
 (objectCall and: [ status = ''failed'' or: [ handoff and: [ status = ''interrupted'' ] ] ])
  ifFalse: [ ^ receipt at: ''ok'' put: false; yourself ].
 saved ifFalse: [ ^ self recoveryReceipt: receipt handoff: handoff ].
 receipt at: ''partialFailure'' put: true ].
(objectCall and: [ saved not ]) ifTrue: [
 receipt at: ''error'' put: ''Codex completed without returning a GT object''.
 ^ self recoveryReceipt: receipt handoff: handoff ].
messages := current at: ''messages''.
(turn at: ''items'' ifAbsent: [ #() ]) do: [ :item |
 (item at: ''type'') = ''agentMessage'' ifTrue: [ messages at: (item at: ''id'') put: item ] ].
rows := messages values.
finals := rows select: [ :item | (item at: ''phase'' ifAbsent: [ nil ]) = ''final_answer'' ].
text := String lf join: ((finals ifEmpty: [ rows ]) collect: [ :item | item at: ''text'' ifAbsent: [ '''' ] ] thenSelect: #isNotEmpty).
(objectCall not and: [ text isEmpty ]) ifTrue: [
 ^ receipt at: ''ok'' put: false; at: ''error'' put: ''Completed Codex turn did not contain an assistant answer''; yourself ].
^ receipt at: ''ok'' put: true; at: ''text'' put: text; yourself'.
transport compile: 'recoveryReceipt: receipt handoff: handoff
 handoff ifTrue: [ receipt at: ''replaceCodexSession'' put: true ].
 ^ receipt at: ''ok'' put: false; at: ''needsRecovery'' put: true; yourself'.
transport compile: 'canHandoffDuring: current
 ^ current notNil and: [ (self isActive: current) and: [
  (current at: ''objectInvocation'' ifAbsent: [ false ]) and: [ (current at: ''turnId'') notNil and: [
  (current at: ''turnProgressEnded'' ifAbsent: [ false ]) not and: [
  (current at: ''releasedAfterSilence'' ifAbsent: [ false ]) not and: [
  (current at: ''handoffRequested'' ifAbsent: [ false ]) not and: [
  (current at: ''interruptionSent'' ifAbsent: [ false ]) not ] ] ] ] ] ] ]'.
transport compile: 'requestHandoffFor: key request: requestId
 | current |
 current := self activeForClient: key.
 (current notNil and: [ (current at: ''clientKey'') = key and: [
  (current at: ''requestId'') = requestId ] ]) ifFalse: [ self error: ''当前轮次已变更，请刷新后重试'' ].
 (self turnProgressLockDuring: current) critical: [
  (self canHandoffDuring: current) ifFalse: [ self error: ''当前轮次无法请求接手'' ].
  self markHandoffDuring: current automatic: false ].
 self interruptDuring: current'.
transport compile: 'markHandoffDuring: current automatic: automatic
 registry recordHandoffRequest: (current at: ''requestId'') turn: (current at: ''turnId'')
  key: (current at: ''clientKey'') thread: (current at: ''threadId'') automatic: automatic.
 current at: ''handoffRequested'' put: true.
 self endNetworkWaitDuring: current title: ''已请求中断旧轮次'''.
transport compile: 'interrupt
 ^ self activeCalls do: [ :current | self interruptDuring: current ]'.
transport compile: 'interruptDuring: current
 | arguments |
 arguments := self claimInterruptDuring: current.
 arguments ifNotNil: [ ^ self rpc: ''turn/interrupt'' params: arguments timeout: 5 ]'.
transport compile: 'claimInterruptDuring: current
 current ifNil: [ ^ nil ].
 ^ (self turnProgressLockDuring: current) critical: [
  | turn |
  turn := current at: ''turnId''.
  ((self isActive: current) not or: [ turn isNil or: [
   (current at: ''turnProgressEnded'' ifAbsent: [ false ]) or: [
   current at: ''interruptionSent'' ifAbsent: [ false ] ] ] ])
    ifTrue: [ nil ]
    ifFalse: [
     current at: ''interruptionSent'' put: true.
     Dictionary new at: ''threadId'' put: (current at: ''threadId''); at: ''turnId'' put: turn; yourself ] ]'.
transport compile: 'sendInterruptWithoutWaitingDuring: current
 | arguments id |
 arguments := self claimInterruptDuring: current.
 arguments ifNil: [ ^ self ].
 "Send a JSON-RPC request without making business delivery depend on its reply."
 self turnsLock critical: [ serial := serial + 1. id := serial ].
 [ self send: (Dictionary new at: ''id'' put: id; at: ''method'' put: ''turn/interrupt'';
    at: ''params'' put: arguments; yourself) ]
   on: Error do: [ :error | current at: ''interruptWriteError'' put: error messageText ]'.
transport compile: 'retire
 reader ifNotNil: #terminate.
(self turnsLock critical: [ toolProcesses copy ]) do: #terminate'.
transport compile: 'stop
 reader ifNotNil: #terminate.
child ifNotNil: [ [ child stdin close ] on: Error do: [ :error | nil ].
 [ child terminate ] on: Error do: [ :error | nil ] ]'.
'GT Codex stdio installed'
