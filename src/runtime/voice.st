"Add audio behavior without reinstalling or replacing the text program."
| voice answer |
voice := (Object << #LMVoice package: 'Loom-Voice') install.
voice class compile: 'featureVersion ^ 2'.
voice class compile: 'directory ^ ExperimentRoot / ''state'' / ''audio'''.
voice class compile: 'index
 | file previous index |
 previous := Smalltalk globals at: #LMVoiceLastIndex ifAbsent: [ Dictionary new at: ''jobs'' put: #(); yourself ].
 file := self directory / ''index.json''.
 [ index := file exists ifTrue: [ STONJSON fromString: file contents ] ifFalse: [ previous ].
   Smalltalk globals at: #LMVoiceLastIndex put: index.
   Smalltalk globals at: #LMVoiceLastReadError put: nil.
   ^ index
 ] on: Error do: [ :error |
  Smalltalk globals at: #LMVoiceLastReadError put: error messageText. ^ previous ]'.
voice class compile: 'job: id
 ^ (self index at: ''jobs'') detect: [ :job | (job at: ''id'') = id ] ifNone: [ nil ]'.
voice class compile: 'jobsById: index
 | jobs |
 jobs := Dictionary new.
 (index at: ''jobs'') do: [ :job | jobs at: (job at: ''id'') put: job ].
 ^ jobs'.
voice class compile: 'transcribedText: job
 ^ (job notNil and: [ (job at: ''state'') = ''completed'' ])
  ifTrue: [ (job at: ''transcript'' ifAbsent: [ '''' ]) trimBoth ] ifFalse: [ '''' ]'.
voice class compile: 'transcriptionStatus: job
 | state |
 job ifNil: [ ^ ''找不到原音'' ].
 state := job at: ''state''.
 state = ''completed'' ifTrue: [
  ^ (self transcribedText: job) ifEmpty: [ ''未识别到语音'' ] ifNotEmpty: [ '''' ] ].
 state = ''failed'' ifTrue: [ ^ job at: ''error'' ifAbsent: [ ''转录失败'' ] ].
 state = ''unknown'' ifTrue: [ ^ ''转录结果待核对'' ].
 ^ ''转录中…'''.
voice class compile: 'request: action options: options
 | id request directory |
 id := UUID new asString.
 request := options copy at: ''action'' put: action; yourself.
 directory := ExperimentRoot / ''ipc'' / ''voice'' / ''requests''.
 directory ensureCreateDirectory.
 LoomConversation write: request to: directory / (id , ''.json'').
 ^ id'.
voice class compile: 'await: id
 | file deadline |
 file := ExperimentRoot / ''ipc'' / ''voice'' / ''results'' / (id , ''.json'').
 deadline := Time millisecondClockValue + 660000.
 [ file exists ] whileFalse: [
  Time millisecondClockValue > deadline ifTrue: [ self error: ''音频操作尚未返回，请查看当前状态'' ].
  (Delay forMilliseconds: 100) wait ].
 ^ STONJSON fromString: file contents'.
voice class compile: 'label: job
 | state duration |
 state := Dictionary new
  at: ''recording'' put: ''录音中''; at: ''draft'' put: ''待发送'';
  at: ''queued'' put: ''等待转录''; at: ''preparing'' put: ''准备音频'';
  at: ''uploading'' put: ''上传中''; at: ''processing'' put: ''转录中'';
  at: ''completed'' put: ''已转录''; at: ''failed'' put: ''需要重试'';
  at: ''unknown'' put: ''需核对订单''; yourself.
 duration := (job at: ''elapsed'' ifAbsent: [ job at: ''duration'' ifAbsent: [ 0 ] ]) rounded.
 ^ (state at: (job at: ''state'') ifAbsent: [ ''音频'' ]), ''  |  '',
  duration asString, '' 秒  |  '', (job at: ''title'')'.
(LMConversation includesSelector: #prepareTextPrompt:) ifFalse: [
 LMConversation compile: 'prepareTextPrompt:' , ((LMConversation >> #preparePrompt:) sourceCode allButFirst: 'preparePrompt:' size) ].
(LMConversation includesSelector: #nextUnansweredInput) ifFalse: [
 LMConversation compile: 'nextUnansweredInput' , ((LMConversation >> #nextInput) sourceCode allButFirst: 'nextInput' size) ].
LMConversation compile: 'submitAudio: audioId text: text
 | id |
 mutex critical: [
  | inputs job message sequence |
  inputs := self orderedInputs.
  (inputs detect: [ :item | (item at: ''audioId'' ifAbsent: [ nil ]) = audioId ] ifNone: [ nil ])
   ifNotNil: [ :existing | ^ existing at: ''id'' ].
  job := LMVoice job: audioId.
  job ifNil: [ self error: ''找不到音频'' ].
  (job at: ''state'') = ''recording'' ifTrue: [ self error: ''请先停止录音'' ].
  (job includesKey: ''messageId'') ifTrue: [ self error: ''此音频已发送'' ].
  text size > 50000 ifTrue: [ self error: ''Message exceeds 50000 characters'' ].
  sequence := inputs ifEmpty: [ 1 ] ifNotEmpty: [ (inputs last at: ''sequence'') + 1 ].
  id := UUID new asString.
  message := Dictionary new at: ''id'' put: id; at: ''sequence'' put: sequence;
   at: ''text'' put: text; at: ''audioId'' put: audioId;
   at: ''createdAt'' put: DateAndTime now asUTC asString; yourself.
  self write: message to: self directory / ''inputs'' / (id , ''.json'') ].
 gate signal. ^ id'.
LMConversation compile: 'nextInput
 | replies jobs |
 replies := self directory / ''replies''.
 self orderedInputs do: [ :message |
  (replies / ((message at: ''id'') , ''.json'')) exists ifFalse: [
   | audioId transcript |
   audioId := message at: ''audioId'' ifAbsent: [ ^ message ].
   jobs ifNil: [ jobs := LMVoice jobsById: LMVoice index ].
   transcript := LMVoice transcribedText: (jobs at: audioId ifAbsent: [ nil ]).
   transcript ifNotEmpty: [ ^ self recordingMessage: message transcript: transcript ] ] ].
 ^ nil'.
LMConversation compile: 'recordingMessage: message transcript: transcript
 | input caption |
 input := message copy.
 caption := input at: ''text''.
 input removeKey: ''audioId''.
 input at: ''kind'' put: ''audio''; at: ''text'' put: transcript.
 caption ifNotEmpty: [ input at: ''caption'' put: caption ].
 ^ input'.
LMConversation compile: 'preparePrompt: message
 ^ self prepareTextPrompt: message'.
answer := (LMConversation >> #answer:) sourceCode.
(answer includesSubstring: '"Answer the user''s request using the prepared context. Read the second argument to get that context. Return the full user-facing reply as a GT String. Keep the Loom invocation protocol out of the user-facing reply."') ifTrue: [
 LMConversation compile: (answer copyReplaceAll:
  'Answer the user''s request using the prepared context. Read the second argument to get that context.'
  with: 'The first argument is the user message and the second is its prepared context. A message with kind audio has the transcript in text.') ].
LMConversation compile: 'transcript
 ^ String streamContents: [ :stream |
  self records do: [ :message |
   stream nextPutAll: ''YOU''; cr; nextPutAll: (message at: ''text''); cr.
   (message at: ''audioId'' ifAbsent: [ nil ]) ifNotNil: [ :id |
    | job |
    job := LMVoice job: id.
    job ifNotNil: [ stream nextPutAll: ''[音频] ''; nextPutAll: (LMVoice label: job); cr.
     stream nextPutAll: (job at: ''transcript'' ifAbsent: [ job at: ''error'' ifAbsent: [ '''' ] ]); cr ] ].
   stream cr.
   (message at: ''reply'' ifAbsent: [ nil ])
    ifNil: [ stream nextPutAll: ''Waiting for a reply...''; cr; cr ]
    ifNotNil: [ :reply |
     stream nextPutAll: ((reply at: ''ok'') ifTrue: [ ''CODEX'' ] ifFalse: [ ''ERROR'' ]);
      cr; nextPutAll: (reply at: ''text''); cr; cr ] ] ]'.

Dictionary new at: 'voiceVersion' put: voice featureVersion; yourself
