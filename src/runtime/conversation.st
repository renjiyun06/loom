"The conversation belongs to the image; GT provides its view."
| conversation existing |
existing := Smalltalk globals at: #LoomConversation ifAbsent: [ nil ].
conversation := (Object << #LMConversation
 slots: { #client. #gate. #worker. #currentId. #mutex };
 package: 'Loom-Conversation') install.
conversation comment: 'A persistent conversation program living in the GT image. SQLite stores messages and replies. The worker waits on a semaphore between messages. Inspect the LoomConversation global for live state.'.
conversation compile: 'initialize
 super initialize. client := LoomCodex session: #main. gate := Semaphore new. mutex := Mutex new'.
conversation class compile: 'bootstrapVersion ^ 2'.
conversation compile: 'directory
 ^ ExperimentRoot / ''state'' / ''conversation'''.
conversation compile: 'write: object to: file
 | temporary |
 "A checkpoint may resume a reply frame compiled before the SQLite upgrade."
 file parent = (self directory / ''replies'') ifTrue: [
  ^ self storage: ''reply'' options: (Dictionary new at: ''reply'' put: object; yourself) ].
 file exists ifTrue: [ ^ self ].
 temporary := file parent / (file basename , ''.tmp'').
 temporary writeStreamDo: [ :stream | stream nextPutAll: (STONJSON toString: object) ].
 temporary renameTo: file basename'.
conversation compile: 'storage: action options: options
 | id ipc request receipt deadline result bridgeStatus |
 id := UUID new asString.
 ipc := ExperimentRoot / ''ipc'' / ''conversation''.
 request := ipc / ''requests'' / (id, ''.json'').
 receipt := ipc / ''results'' / (id, ''.json'').
 self write: (options copy at: ''action'' put: action; yourself) to: request.
 deadline := DateAndTime now + (Duration seconds: (action = ''pick'' ifTrue: [ 605 ] ifFalse: [ 30 ])).
 bridgeStatus := ExperimentRoot / ''ipc'' / ''bridge-ready.json''.
 [ receipt exists ] whileFalse: [
  DateAndTime now >= deadline ifTrue: [
   | phase |
   phase := [ (STONJSON fromString: bridgeStatus contents) at: ''status'' ]
    on: Error do: [ :error | nil ].
   ((#(''submit'' ''reply'') includes: action) and: [ phase = ''ready'' ])
    ifFalse: [ self error: ''对话存储尚未返回，请查看当前状态'' ].
   deadline := DateAndTime now + (Duration seconds: 30) ].
  (Delay forMilliseconds: 30) wait ].
 [ result := STONJSON fromString: receipt contents ]
  ensure: [ request ensureDelete. receipt ensureDelete ].
 (result at: ''ok'') ifFalse: [ self error: (result at: ''error'') ].
 ^ result at: ''value'''.
conversation compile: 'storage: action
 ^ self storage: action options: Dictionary new'.
conversation compile: 'storageRevision
 | file |
 file := ExperimentRoot / ''ipc'' / ''conversation'' / ''revision.json''.
 ^ file exists ifTrue: [ file contents ] ifFalse: [ nil ]'.
conversation compile: 'attachment: id
 ^ self storage: ''attachment'' options: (Dictionary new at: ''attachmentId'' put: id; yourself)'.
conversation compile: 'fileForAttachment: attachment
 ^ self directory resolve: (attachment at: ''relativePath'')'.
conversation compile: 'inputs
 ^ self records collect: [ :record |
  record copy removeKey: ''reply'' ifAbsent: [ ]; removeKey: ''attachments'' ifAbsent: [ ]; yourself ]'.
conversation compile: 'orderedInputs ^ self inputs'.
conversation compile: 'submit: text
 ^ self submit: text files: #()'.
conversation compile: 'submit: text files: files
 ^ self submitMessage: (Dictionary new at: ''text'' put: text; at: ''files'' put: files; yourself)'.
conversation compile: 'submitMessage: message
 | id |
 id := mutex critical: [
  self storage: ''submit'' options: (message copy
   at: ''id'' put: UUID new asString;
   at: ''createdAt'' put: DateAndTime now asUTC asString; yourself) ].
 gate signal.
 ^ id'.
conversation compile: 'pendingInputs ^ self storage: ''pending'''.
conversation compile: 'nextUnansweredInput
 ^ self pendingInputs ifEmpty: [ nil ] ifNotEmpty: [ :messages | messages first ]'.
conversation compile: 'nextInput ^ self nextUnansweredInput'.
conversation compile: 'preparePrompt: message
 "This is the first replaceable context preparation method."
 ^ message at: ''text'''.
conversation compile: (ExperimentRoot / 'src' / 'runtime' / 'conversation-answer.st') contents.
conversation compile: 'process: message
 | reply id |
 id := message at: ''id''.
 currentId := id.
 [
  [ reply := Dictionary new at: ''ok'' put: true;
    at: ''text'' put: (self answer: message);
    at: ''invocation'' put: client lastResponse; yourself
  ] on: Error do: [ :error |
   reply := Dictionary new at: ''ok'' put: false;
    at: ''text'' put: error messageText;
    at: ''invocation'' put: client lastResponse; yourself ].
  reply at: ''id'' put: id; at: ''completedAt'' put: DateAndTime now asUTC asString.
  self storage: ''reply'' options: (Dictionary new at: ''reply'' put: reply; yourself)
 ] ensure: [ currentId := nil ]'.
conversation compile: 'run
 | message |
 [ true ] whileTrue: [
  message := self nextInput.
  message ifNil: [ gate wait ] ifNotNil: [ self process: message ] ]'.
conversation compile: 'start
 self directory.
 (worker isNil or: [ worker isTerminated ]) ifTrue: [
  worker := [ self run ] fork.
  worker name: ''Loom conversation loop'' ].
 gate signal.
 ^ self'.
conversation compile: 'records ^ self storage: ''records'''.
conversation compile: 'state
 ^ Dictionary new at: ''currentId'' put: currentId;
  at: ''threadId'' put: client threadId;
  at: ''waiting'' put: (currentId isNil and: [ self nextInput isNil ]);
  at: ''messages'' put: self records asArray; yourself'.
conversation compile: 'statusText
 currentId ifNotNil: [ ^ ''正在处理'' ].
 self nextInput ifNotNil: [ ^ ''消息待处理'' ].
 ^ ''等待消息'''.
conversation compile: 'transcript
 ^ String streamContents: [ :stream |
  self records do: [ :message |
   stream nextPutAll: ''YOU''; cr; nextPutAll: (message at: ''text''); cr; cr.
   (message at: ''reply'' ifAbsent: [ nil ])
    ifNil: [ stream nextPutAll: ''Waiting for a reply...''; cr; cr ]
    ifNotNil: [ :reply |
     stream nextPutAll: ((reply at: ''ok'') ifTrue: [ ''CODEX'' ] ifFalse: [ ''ERROR'' ]);
      cr; nextPutAll: (reply at: ''text''); cr; cr ] ] ]'.
conversation compile: 'open
 (Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ]) ifFalse: [ self error: ''Start with start.ps1 -Gui to open the native window'' ].
 ^ (Smalltalk globals at: #LMConversationUI) openConversation'.


Smalltalk globals at: #LoomConversation put: (existing ifNil: [ conversation new ]).
'conversation model installed'
