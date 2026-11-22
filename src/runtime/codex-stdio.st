"Speak Codex App Server JSON-RPC from GT; native process handles are scoped to this VM."
| transport |
transport := (Object << #LMNativeCodexTransport slots: #(#child #reader #pending #loaded #models #toolProcesses #writeMutex #serial #session #epoch #registry #failure #active); package: 'Loom-Codex') install.
transport compile: 'start: options registry: aRegistry
 | builder cwd temp logs identity |
registry := aRegistry.
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
serial := serial + 1.
id := serial.
pending at: id put: nil.
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
transport compile: 'receive: message
 | id method params current turnId |
id := message at: ''id'' ifAbsent: [ nil ].
method := message at: ''method'' ifAbsent: [ nil ].
method ifNil: [
 (id notNil and: [ pending includesKey: id ]) ifTrue: [ pending at: id put: message ].
 ^ self ].
params := message at: ''params'' ifAbsent: [ Dictionary new ].
current := active.
(current notNil and: [ (params at: ''threadId'' ifAbsent: [ nil ]) = (current at: ''threadId'') ]) ifTrue: [
 turnId := params at: ''turnId'' ifAbsent: [ (params at: ''turn'' ifAbsent: [ Dictionary new ]) at: ''id'' ifAbsent: [ nil ] ].
 (turnId isNil or: [ (current at: ''turnId'') isNil or: [ turnId = (current at: ''turnId'') ] ]) ifTrue: [
  registry acceptActivity: message call: (current at: ''requestId'').
  method = ''item/completed'' ifTrue: [
   | item |
   item := params at: ''item''.
   (item at: ''type'') = ''agentMessage'' ifTrue: [ (current at: ''messages'') at: (item at: ''id'') put: item ] ].
  method = ''turn/completed'' ifTrue: [ current at: ''completed'' put: (params at: ''turn'') ] ] ].
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
transport compile: 'permitsTool: params during: current
 ^ current notNil and: [ active == current and: [ (current at: ''threadId'') notNil and: [
 (params at: ''tool'' ifAbsent: [ nil ]) = ''runtime_eval'' and: [
 (params at: ''threadId'' ifAbsent: [ nil ]) = (current at: ''threadId'') and: [
 | turn |
 turn := params at: ''turnId'' ifAbsent: [ nil ].
 turn isNil or: [ (current at: ''turnId'') isNil or: [ turn = (current at: ''turnId'') ] ] ] ] ] ] ]'.
transport compile: 'evaluateTool: raw during: current
 | arguments source value sessionId block evaluated |
arguments := raw isString ifTrue: [ STONJSON fromString: raw ] ifFalse: [ raw ].
source := arguments at: ''code''.
source isString ifFalse: [ self error: ''Expected Smalltalk source in code'' ].
(current at: ''objectInvocation'')
 ifFalse: [ value := Smalltalk compiler evaluate: source ]
 ifTrue: [
  sessionId := registry sessionIdFor: (current at: ''clientKey'').
  block := Smalltalk compiler evaluate:
   (''[ :loomCaller :loomMessage :loomSessionId :loomReturn |'', String cr, source, String cr, '']'').
  evaluated := (LMInvocation pendingAt: (current at: ''requestId'')) evaluate: block sessionId: sessionId.
  evaluated first ifTrue: [
   (current at: ''objectSaved'' ifAbsent: [ false ]) ifFalse: [
    LMExecution checkpoint.
    current at: ''objectSaved'' put: true ] ].
  value := evaluated second ].
STONJSON toString: value.
^ Dictionary new at: ''ok'' put: true; at: ''value'' put: value; yourself'.
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
  | thread turn response params |
  thread := self openThreadFor: current request: request in: workspace.
  params := settings copy at: ''threadId'' put: thread;
   at: ''input'' put: {Dictionary new at: ''type'' put: ''text''; at: ''text'' put: (request at: ''prompt'');
    at: ''text_elements'' put: #(); yourself}; yourself.
  response := self rpc: ''turn/start'' params: params.
  current at: ''turnId'' put: ((response at: ''turn'') at: ''id'').
  [ (turn := current at: ''completed'' ifAbsent: [ nil ]) isNil ] whileTrue: [
   self checkAlive.
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
 | rows finals text messages |
messages := current at: ''messages''.
(turn at: ''items'' ifAbsent: [ #() ]) do: [ :item |
 (item at: ''type'') = ''agentMessage'' ifTrue: [ messages at: (item at: ''id'') put: item ] ].
(turn at: ''status'') = ''completed'' ifFalse: [
 self error: ((turn at: ''error'' ifAbsent: [ nil ])
  ifNil: [ ''Codex turn '', (turn at: ''status'') ] ifNotNil: [ :error | error at: ''message'' ]) ].
rows := messages values.
finals := rows select: [ :item | (item at: ''phase'' ifAbsent: [ nil ]) = ''final_answer'' ].
text := String lf join: ((finals ifEmpty: [ rows ]) collect: [ :item | item at: ''text'' ifAbsent: [ '''' ] ] thenSelect: #isNotEmpty).
(current at: ''objectInvocation'')
 ifTrue: [ (current at: ''objectSaved'' ifAbsent: [ false ]) ifFalse: [ self error: ''Codex completed without returning a GT object'' ] ]
 ifFalse: [ text ifEmpty: [ self error: ''Completed Codex turn did not contain an assistant answer'' ] ].
^ (self receiptFrom: current) at: ''ok'' put: true; at: ''text'' put: text; at: ''model'' put: model; yourself'.
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
