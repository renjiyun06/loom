"The conversation belongs to the image; GT provides its view."
| conversation existing |
existing := Smalltalk globals at: #LoomConversation ifAbsent: [ nil ].
conversation := (Object << #LMConversation
 slots: { #client. #gate. #worker. #currentId. #mutex. #pendingReply. #closingBrowser };
 package: 'Loom-Conversation') install.
conversation comment: 'A persistent conversation program living in the GT image. SQLite stores messages and replies. The worker waits on a semaphore between messages. Inspect the LoomConversation global for live state.'.
conversation compile: 'initialize
 super initialize. client := LoomCodex session: #main. gate := Semaphore new. mutex := Mutex new'.
conversation class compile: 'bootstrapVersion ^ 4'.
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
 | store |
 self waitForStorage.
 store := Smalltalk globals at: #LoomConversationStore.
 action = ''records'' ifTrue: [ ^ store records ].
 action = ''pending'' ifTrue: [ ^ store pending ].
 action = ''audio-messages'' ifTrue: [ ^ store audioMessages ].
 action = ''attachment'' ifTrue: [ ^ store attachment: (options at: ''attachmentId'') ].
 action = ''submit'' ifTrue: [ ^ store submit: options ].
 action = ''reply'' ifTrue: [ ^ store saveReply: (options at: ''reply'') ].
 action = ''stage-browser-reply'' ifTrue: [ ^ store stageBrowserReply: (options at: ''reply'') ].
 action = ''staged-browser-reply'' ifTrue: [ ^ store stagedBrowserReplyAt: (options at: ''id'') ].
 action = ''pick'' ifTrue: [ ^ LMPlatformTools selectFiles ].
 self error: ''未知对话操作'''.
conversation compile: 'storageStatus ^ LoomApplications statusFor: ''conversation'''.
conversation compile: 'checkStorageFailure
 | status |
 status := self storageStatus.
 (status at: ''phase'') = ''failed'' ifTrue: [
  self error: ''对话存储不可用：'', (status at: ''error'') ].
 ^ status at: ''phase'''.
conversation compile: 'waitForStorage
 | deadline |
 deadline := DateAndTime now + (Duration seconds: 30).
 [ self checkStorageFailure = ''ready'' ] whileFalse: [
  DateAndTime now >= deadline ifTrue: [ self error: ''对话存储尚未就绪'' ].
  (Delay forMilliseconds: 50) wait ]'.
conversation compile: 'storage: action
 ^ self storage: action options: Dictionary new'.
conversation compile: 'storageRevision
 ^ (Smalltalk globals at: #LoomConversationStore ifAbsent: [ nil ]) ifNotNil: #revision'.
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
conversation compile: 'isProcessing ^ currentId notNil'.
conversation compile: 'submitMessage: message
 | id |
 id := mutex critical: [
  (self isProcessing or: [ self nextInput notNil ]) ifTrue: [
   self error: ''请等当前消息处理完成后再发送'' ].
  self storage: ''submit'' options: (message copy
   at: ''id'' put: UUID new asString;
   at: ''createdAt'' put: DateAndTime now asUTC asString; yourself) ].
 gate signal.
 ^ id'.
conversation compile: 'pendingInputs ^ self storage: ''pending'''.
conversation compile: 'nextUnansweredInput
 ^ self pendingInputs ifEmpty: [ nil ] ifNotEmpty: [ :messages | messages first ]'.
conversation compile: 'preparePrompt: message
 "This is the first replaceable context preparation method."
 ^ message at: ''text'''.
conversation compile: (ExperimentRoot / 'src' / 'runtime' / 'conversation-answer.st') contents.
conversation compile: 'isClosingBrowser ^ closingBrowser == true'.
conversation compile: 'captureReplyTo: message
 | result text action |
 result := self answer: message.
 result isString
  ifTrue: [ text := result. action := ''none'' ]
  ifFalse: [
   result isDictionary ifFalse: [ self error: ''回复必须是字典或字符串'' ].
   text := result at: ''text'' ifAbsent: [ nil ].
   action := result at: ''browserAction'' ifAbsent: [ nil ].
   (text isString and: [ #(''none'' ''keep'' ''close'') includes: action ])
    ifFalse: [ self error: ''回复正文或浏览器处置值无效'' ] ].
 ^ Dictionary new at: ''ok'' put: true; at: ''text'' put: text;
  at: ''browserAction'' put: action asString; at: ''invocation'' put: client lastResponse; yourself'.
conversation compile: 'browserCloseFailure: reason
 ^ Dictionary new at: ''ok'' put: false; at: ''error'' put: reason; yourself'.
conversation compile: 'closeBrowserFor: answerReceipt using: session
 "Close only the browser used by the reply invocation identified by the first argument.
 Use the same browser tool and verify the instance belongs to the current Loom session
 and is the one used by that invocation. Leave user-owned browsers and uncertain
 targets alone. Return a GT Dictionary through loomReturn with ok true if that
 instance is confirmed closed, or ok false and an error String otherwise."
 ^ session requireThread: (answerReceipt at: ''threadId'')
  during: [ session closeBrowserUsedFor: (answerReceipt at: ''id'') ]'.
conversation compile: 'performBrowserCloseFor: reply
 | result |
 closingBrowser := true.
 [ result := [
   | outcome ok reason |
    outcome := self closeBrowserFor: (reply at: ''invocation'') using: client.
    outcome isDictionary ifFalse: [ self error: ''浏览器关闭回执无效'' ].
    ok := outcome at: ''ok'' ifAbsent: [ nil ].
    ok == true
     ifTrue: [ Dictionary new at: ''ok'' put: true; yourself ]
     ifFalse: [
      reason := outcome at: ''error'' ifAbsent: [ nil ].
      (ok == false and: [ reason isString and: [ reason trimBoth isNotEmpty ] ])
       ifFalse: [ self error: ''浏览器关闭回执无效'' ].
      self browserCloseFailure: reason ]
   ] on: Error do: [ :error | self browserCloseFailure: error messageText ].
   reply at: ''browserClose'' put: result
 ] ensure: [ closingBrowser := false ]'.
conversation compile: 'process: message
 | reply id |
 id := message at: ''id''.
 mutex critical: [ currentId := id ].
 [
  reply := self storage: ''staged-browser-reply'' options: (Dictionary new at: ''id'' put: id; yourself).
  reply ifNil: [
   reply := [ self captureReplyTo: message ] on: Error do: [ :error |
    Dictionary new at: ''ok'' put: false; at: ''text'' put: error messageText;
     at: ''invocation'' put: client lastResponse; yourself ].
   reply at: ''id'' put: id.
   (reply at: ''browserAction'' ifAbsent: [ ''none'' ]) = ''close'' ifTrue: [
    self storage: ''stage-browser-reply'' options: (Dictionary new at: ''reply'' put: reply; yourself).
    self performBrowserCloseFor: reply ] ]
  ifNotNil: [
   "A fresh worker has no proof that an earlier cleanup call did or did not close the browser."
   reply at: ''browserClose'' put: (self browserCloseFailure: ''关闭状态待确认'') ].
  reply at: ''id'' put: id; at: ''completedAt'' put: DateAndTime now asUTC asString.
  pendingReply := reply.
  self flushReply
 ] ensure: [ currentId := nil ]'.
conversation compile: 'flushReply
 pendingReply ifNotNil: [
  self storage: ''reply'' options: (Dictionary new at: ''reply'' put: pendingReply; yourself).
  pendingReply := nil ]'.
conversation compile: 'run
 | message |
 [ true ] whileTrue: [
  [ self flushReply.
   message := self nextInput.
   message ifNil: [ gate wait ] ifNotNil: [ self process: message ]
  ] on: Error do: [ :error |
   ((self storageStatus at: ''phase'') = ''ready'')
    ifTrue: [ error pass ] ifFalse: [ gate wait ] ] ]'.
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
