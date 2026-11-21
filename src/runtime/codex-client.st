"Codex transport shared by text and live-object calls."
| clientClass client existing |
existing := Smalltalk globals at: #LoomCodex ifAbsent: [ nil ].
clientClass := (Object << #LMCodexClient
 slots: { #threadId. #lastResponse. #timeoutSeconds. #mutex. #clientKey. #activeRequestId };
 package: 'Loom-Bridge') install.
clientClass compile: 'initialize
 super initialize. timeoutSeconds := nil. mutex := Mutex new. clientKey := UUID new asString'.
clientClass compile: 'clientKey ^ clientKey'.
clientClass compile: 'clientKey: key clientKey := key'.
clientClass compile: 'synchronizeThreadId: value threadId := value'.
clientClass compile: 'threadId ^ threadId'.
clientClass compile: 'lastResponse ^ lastResponse'.
clientClass compile: 'timeoutSeconds: seconds
 "Compatibility entry point. Model turns have no duration limit."
 seconds ifNotNil: [ self error: ''Model turns have no duration limit; use explicit cancellation'' ].
 timeoutSeconds := nil'.
clientClass compile: 'newConversation
 ^ mutex critical: [ [ self performRequest: '''' action: ''newConversation'' ] ensure: [ activeRequestId := nil ] ]'.
clientClass compile: 'configure: settings
 ^ mutex critical: [ | previous |
  previous := lastResponse.
  [ self performRequest: (STONJSON toString: settings) action: ''configure'' ]
   ensure: [ lastResponse := previous. activeRequestId := nil ] ]'.
clientClass compile: 'ask: prompt
 ^ mutex critical: [ [ self performRequest: prompt action: ''ask'' ] ensure: [ activeRequestId := nil ] ]'.
clientClass compile: 'performRequest: prompt action: action
 ^ self performRequest: prompt action: action invocation: nil'.
clientClass compile: 'performRequest: prompt action: action invocation: invocation
 | id request outgoing responseFile ready |
 ready := BridgeIPC / ''bridge-ready.json''.
 ready exists ifFalse: [ self error: ''Codex bridge is not running'' ].
 ready := STONJSON fromString: ready contents.
 (ready at: ''status'') = ''ready''
  ifFalse: [ self error: ''Codex bridge is not ready'' ].
 (invocation notNil and: [ (ready at: ''objectInvocation'' ifAbsent: [ false ]) not ])
  ifTrue: [ self error: ''The running bridge does not support Loom object invocation'' ].
 (action = ''ask'' and: [ (prompt isString and: [ prompt isNotEmpty ]) not ])
  ifTrue: [ self error: ''Prompt must be a nonempty string'' ].
 (clientKey isString and: [ clientKey isNotEmpty ])
  ifFalse: [ self error: ''Conversation client key is missing'' ].
 id := UUID new asString.
 activeRequestId := id.
 request := Dictionary new
  at: ''id'' put: id;
  at: ''prompt'' put: prompt;
  at: ''clientKey'' put: clientKey;
  at: ''action'' put: action;
  at: ''threadId'' put: threadId;
  yourself.
 invocation ifNotNil: [
  invocation attachTo: id.
  request at: ''objectInvocation'' put: true ].
 LMExecution checkpoint.
 (BridgeIPC / ''codex-requests'' / (id , ''.json'')) exists ifFalse: [
  outgoing := BridgeIPC / ''codex-requests'' / (id , ''.tmp'').
  outgoing writeStreamDo: [ :s | s nextPutAll: (STONJSON toString: request) ].
  outgoing renameTo: id , ''.json'' ].
 responseFile := BridgeIPC / ''codex-responses'' / (id , ''.json'').
 [ responseFile exists ] whileFalse: [
  (Delay forMilliseconds: 30) wait ].
 lastResponse := STONJSON fromString: responseFile contents.
 (lastResponse includesKey: ''threadId'') ifTrue: [ threadId := lastResponse at: ''threadId'' ].
 (lastResponse at: ''ok'') ifFalse: [ self error: (lastResponse at: ''error'') ].
 ^ lastResponse at: ''text'''.
clientClass compile: 'activeRequestId ^ activeRequestId'.
Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'object-invocation.st') contents.
Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'loom-sessions.st') contents.
clientClass class compile: 'bridgeVersion ^ 11'.
client := existing ifNil: [ clientClass new ].
client timeoutSeconds: nil.
Smalltalk globals at: #LoomCodex put: client.
Dictionary new at: 'installed' put: clientClass name; yourself
