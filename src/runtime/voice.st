"Add audio behavior without reinstalling or replacing the text program."
| voice |
voice := (Object << #LMVoice package: 'Loom-Voice') install.
voice class compile: 'featureVersion ^ 1'.
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
 | job id message sequence |
 job := LMVoice job: audioId.
 job ifNil: [ self error: ''找不到音频'' ].
 (job at: ''state'') = ''recording'' ifTrue: [ self error: ''请先停止录音'' ].
 (job includesKey: ''messageId'') ifTrue: [ self error: ''此音频已发送'' ].
 text size > 50000 ifTrue: [ self error: ''Message exceeds 50000 characters'' ].
 mutex critical: [
  (self inputs anySatisfy: [ :item | (item at: ''audioId'' ifAbsent: [ nil ]) = audioId ])
   ifTrue: [ self error: ''此音频已发送'' ].
  sequence := self orderedInputs ifEmpty: [ 1 ] ifNotEmpty: [ :items | (items last at: ''sequence'') + 1 ].
  id := UUID new asString.
  message := Dictionary new at: ''id'' put: id; at: ''sequence'' put: sequence;
   at: ''text'' put: text; at: ''audioId'' put: audioId;
   at: ''createdAt'' put: DateAndTime now asUTC asString; yourself.
  self write: message to: self directory / ''inputs'' / (id , ''.json'') ].
 LMVoice request: ''submit'' options: (Dictionary new at: ''audioId'' put: audioId; at: ''messageId'' put: id; yourself).
 gate signal. ^ id'.
LMConversation compile: 'nextInput
 ^ self orderedInputs detect: [ :message |
  (self directory / ''replies'' / ((message at: ''id'') , ''.json'')) exists not and: [
   (message includesKey: ''audioId'') not or: [
    | job | job := LMVoice job: (message at: ''audioId'').
    job notNil and: [ (job at: ''state'') = ''completed'' ] ] ]
 ] ifNone: [ nil ]'.
LMConversation compile: 'preparePrompt: message
 | job |
 (message includesKey: ''audioId'') ifFalse: [ ^ self prepareTextPrompt: message ].
 job := LMVoice job: (message at: ''audioId'').
 ^ String streamContents: [ :stream |
  stream nextPutAll: (self prepareTextPrompt: message); cr;
   nextPutAll: ''用户发送了一条音频消息。以下为讯飞文件转写文本，可能存在识别错误。当前模型输入是转录文本，并非直接接收了原音。''; cr;
   nextPutAll: ''原音：''; nextPutAll: (LMVoice directory / (job at: ''id'') / (job at: ''original'')) fullName; cr;
   nextPutAll: ''转录：''; cr; nextPutAll: (job at: ''transcript'' ifAbsent: [ '''' ]) ]'.
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
