"The conversation belongs to the image; GT provides its view."
| conversation existing |
existing := Smalltalk globals at: #LoomConversation ifAbsent: [ nil ].
conversation := (Object << #LMConversation
 slots: { #client. #gate. #worker. #currentId. #mutex };
 package: 'Loom-Conversation') install.
conversation comment: 'A persistent conversation program living in the GT image. Inputs and replies are durable files; the worker waits on a semaphore between messages. preparePrompt: and answer: are replaceable behavior. client uses the existing Codex thread. Inspect the LoomConversation global for live state.'.
conversation compile: 'initialize
 super initialize. client := LoomCodex session: #main. gate := Semaphore new. mutex := Mutex new'.
conversation class compile: 'bootstrapVersion ^ 1'.
conversation compile: 'directory
 | directory |
 directory := ExperimentRoot / ''state'' / ''conversation''.
 directory ensureCreateDirectory.
 (directory / ''inputs'') ensureCreateDirectory.
 (directory / ''replies'') ensureCreateDirectory.
 ^ directory'.
conversation compile: 'write: object to: file
 | temporary |
 file exists ifTrue: [ ^ self ].
 temporary := file parent / (file basename , ''.tmp'').
 temporary writeStreamDo: [ :stream | stream nextPutAll: (STONJSON toString: object) ].
 temporary renameTo: file basename'.
conversation compile: 'inputs
 ^ ((self directory / ''inputs'') files
  select: [ :file | file extension = ''json'' ])
  collect: [ :file | STONJSON fromString: file contents ]'.
conversation compile: 'orderedInputs
 ^ self inputs sorted: [ :a :b | (a at: ''sequence'') < (b at: ''sequence'') ]'.
conversation compile: 'submit: text
 | id message sequence |
 (text isString and: [ text trimBoth isNotEmpty ])
  ifFalse: [ self error: ''Please enter a message'' ].
 text size > 50000 ifTrue: [ self error: ''Message exceeds 50000 characters'' ].
 mutex critical: [
  sequence := self orderedInputs ifEmpty: [ 1 ] ifNotEmpty: [ :items | (items last at: ''sequence'') + 1 ].
  id := UUID new asString.
  message := Dictionary new
   at: ''id'' put: id; at: ''sequence'' put: sequence;
   at: ''text'' put: text; at: ''createdAt'' put: DateAndTime now asUTC asString; yourself.
  self write: message to: self directory / ''inputs'' / (id , ''.json'') ].
 gate signal.
 ^ id'.
conversation compile: 'nextInput
 ^ self orderedInputs detect: [ :message |
  (self directory / ''replies'' / ((message at: ''id'') , ''.json'')) exists not
 ] ifNone: [ nil ]'.
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
  self write: reply to: self directory / ''replies'' / (id , ''.json'')
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
conversation compile: 'records
 ^ self orderedInputs collect: [ :message |
  | copy file |
  copy := message copy.
  file := self directory / ''replies'' / ((message at: ''id'') , ''.json'').
  file exists ifTrue: [ copy at: ''reply'' put: (STONJSON fromString: file contents) ].
  copy ]'.
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
