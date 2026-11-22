"Audio jobs and persisted recovery are owned by GT."
| service |
service := (Object << #LMGtVoice slots: #(#directory #host #media #provider #session #jobs #operations #control #poller #recorder #player #closed #conversationRevision); package: 'Loom-Voice') install.
service compile: 'initializeAt: root forSession: identifier
 directory := root / ''state'' / ''audio''.
host := root / ''runtime'' / ''audio'' / ''AudioHost.exe''.
media := root / ''runtime'' / ''media''.
provider := LMXfyun new file: root / ''config'' / ''xfyun.local.json''; yourself.
session := identifier.
jobs := Dictionary new.
operations := Dictionary new.
control := Mutex new.
closed := false.
directory ensureCreateDirectory.
directory directories do: [ :entry |
 | file job |
 file := entry / ''message.json''.
 file exists ifTrue: [
  job := STONJSON fromString: file contents.
  (job at: ''id'') = entry basename ifFalse: [ self error: ''Invalid audio record: '', entry basename ].
  jobs at: (job at: ''id'') put: job.
  (job at: ''state'') = ''uploading'' ifTrue: [
   job at: ''state'' put: ''unknown''; at: ''error'' put: ''上次上传中断，未自动重传。请核对讯飞订单。''.
   self save: job ].
  (job at: ''state'') = ''recording'' ifTrue: [
   job at: ''state'' put: ''draft''; at: ''error'' put: ''录音因运行环境停止而结束，已保留现有音频。''.
   self save: job ].
  (job at: ''state'') = ''preparing'' ifTrue: [ job at: ''state'' put: ''queued''. self save: job ] ] ]'.
service compile: 'session
 ^ session'.
service compile: 'provider: aProvider
 provider := aProvider'.
service compile: 'isCurrent
 ^ session = BridgeRuntimeSessionId'.
service compile: 'isClosed
 ^ closed'.
service compile: 'fileFor: job named: name
 ^ (directory / (job at: ''id'')) resolve: name'.
service compile: 'job: id
 ^ jobs at: id ifAbsent: [ self error: ''音频不存在。'' ]'.
service compile: 'save: job
 self isCurrent ifFalse: [ ^ self ].
job at: ''updatedAt'' put: DateAndTime now asUTC asString.
LMPlatformTools writeJSON: job to: (self fileFor: job named: ''message.json'')'.
service compile: 'makeJob: title original: filename
 | job |
job := Dictionary new at: ''id'' put: UUID new asString; at: ''title'' put: title;
 at: ''state'' put: ''draft''; at: ''createdAt'' put: DateAndTime now asUTC asString;
 at: ''original'' put: filename; yourself.
self save: job.
jobs at: (job at: ''id'') put: job.
^ job'.
service compile: 'index
 ^ Dictionary new
 at: ''configured'' put: provider configured;
 at: ''recordingId'' put: (recorder ifNotNil: [ recorder at: ''id'' ]);
 at: ''playingId'' put: (player ifNotNil: [ player at: ''id'' ]);
 at: ''jobs'' put: (jobs values collect: [ :job |
  job copy at: ''elapsed'' put: ((job at: ''state'') = ''recording''
   ifTrue: [ (DateAndTime now - (DateAndTime fromString: (job at: ''createdAt''))) asSeconds ]
   ifFalse: [ job at: ''duration'' ifAbsent: [ 0 ] ]); yourself ]);
 yourself'.
service compile: 'meter
 ^ recorder ifNil: [ Dictionary new at: ''audioId'' put: nil; at: ''state'' put: nil; at: ''levels'' put: #(); yourself ]
 ifNotNil: [ :active |
 Dictionary new at: ''audioId'' put: (active at: ''id'');
  at: ''state'' put: (active at: ''state''); at: ''levels'' put: (active at: ''levels'') asArray; yourself ]'.
service compile: 'probe: file
 | output seconds |
output := LMPlatformTools run: media / ''ffprobe.exe''
 arguments: #(''-v'' ''error'' ''-show_entries'' ''format=duration'' ''-of'' ''json''), {file fullName} timeout: 20.
seconds := ((STONJSON fromString: output) at: ''format'') at: ''duration''.
seconds := seconds asNumber.
(seconds > 0 and: [ seconds <= 18000 ]) ifFalse: [ self error: ''音频为空或超过5小时。'' ].
^ seconds'.
service compile: 'convert: job named: name format: format
 | target source temporary |
target := self fileFor: job named: name.
target exists ifTrue: [ ^ target ].
source := self fileFor: job named: (job at: ''original'').
temporary := target parent / (name, ''.'', UUID new asString, ''.partial'').
[
 LMPlatformTools run: media / ''ffmpeg.exe''
  arguments: #(''-nostdin'' ''-v'' ''error'' ''-y'' ''-protocol_whitelist'' ''file,pipe'' ''-i''), {source fullName},
   #(''-vn'' ''-ac'' ''1'' ''-ar'' ''16000'' ''-sample_fmt'' ''s16'' ''-f''), {format. temporary fullName} timeout: 300.
 (LMPlatformTools move: temporary to: target) = 0 ifTrue: [ self error: ''无法保存转码音频'' ].
 ^ target
] ensure: [ temporary ensureDelete ]'.
service compile: 'waitUntil: condition for: seconds
 | deadline |
deadline := DateAndTime now + (Duration seconds: seconds).
[ condition value ] whileFalse: [
 DateAndTime now >= deadline ifTrue: [ self error: ''录音设备未响应。'' ].
 (Delay forMilliseconds: 25) wait ]'.
service compile: 'idReceipt: id
 ^ Dictionary new at: ''audioId'' put: id; yourself'.
service compile: 'record
 | job id child active |
recorder ifNotNil: [ self error: ''已有录音正在进行。'' ].
self stopPlayback.
job := self makeJob: ''录音 '', DateAndTime now asLocal asString original: ''original.wav''.
id := job at: ''id''.
job at: ''state'' put: ''recording''; at: ''source'' put: ''microphone''.
self save: job.
[
 child := LMPlatformTools interactive: host arguments: { ''record''. (self fileFor: job named: ''original.wav'') fullName }.
 active := Dictionary new at: ''id'' put: id; at: ''state'' put: ''starting'';
  at: ''child'' put: child; at: ''levels'' put: OrderedCollection new; yourself.
 recorder := active.
 active at: ''monitor'' put: ([ self monitorRecording: active job: job ] fork).
 self waitUntil: [ (active at: ''state'') = ''recording'' or: [ recorder isNil ] ] for: 10.
 recorder ifNil: [ self error: ''录音设备不可用或音频为空。'' ].
 ^ self idReceipt: id
] on: Error do: [ :error |
 active ifNil: [
  job at: ''state'' put: ''failed''; at: ''error'' put: ''无法启动麦克风录音。''.
  self save: job
 ] ifNotNil: [ self stopRecording: id ].
 error pass ]'.
service compile: 'monitor: child lines: consume
 | stream pending delimiter chunk |
 stream := child asynchronousStdout.
 pending := ''''.
 [
  chunk := stream pollString.
  pending := pending, chunk.
  [ delimiter := pending indexOf: Character lf. delimiter > 0 ] whileTrue: [
   consume value: (pending first: delimiter - 1) trimRight.
   pending := pending allButFirst: delimiter ].
  (chunk isEmpty and: [ stream isEndOfStreamReached or: [ child isTerminated ] ]) ifTrue: [
   pending ifNotEmpty: [ consume value: pending trimRight ].
   ^ self ].
  (Delay forMilliseconds: 25) wait
 ] repeat'.
service compile: 'monitorRecording: active job: job
 | child status |
child := active at: ''child''.
[ self monitor: child lines: [ :line | self recordingLine: line on: active ].
  self isCurrent ifTrue: [ status := child wait ]
] ensure: [
 self isCurrent ifTrue: [ self finishRecording: active job: job exitStatus: status ] ]'.
service compile: 'recordingLine: line on: active
 | levels |
(#(''recording'' ''resumed'') includes: line) ifTrue: [ active at: ''state'' put: ''recording'' ].
line = ''paused'' ifTrue: [ active at: ''state'' put: ''paused'' ].
(line beginsWith: ''level '') ifTrue: [
 levels := active at: ''levels''.
 levels add: ((line allButFirst: 6) asNumber min: 100).
 levels size > 24 ifTrue: [ levels removeFirst ] ]'.
service compile: 'finishRecording: active job: job exitStatus: status
 [
 active at: ''state'' put: ''finishing''.
 job at: ''state'' put: ''draft''.
 [ job at: ''duration'' put: (self probe: (self fileFor: job named: (job at: ''original''))).
   (status isNil or: [ status isSuccess not ]) ifTrue: [ job at: ''error'' put: ''录音已中断，现有音频已保留。'' ]
 ] on: Error do: [ :error |
  job at: ''state'' put: ''failed''; at: ''error'' put: ''录音设备不可用或音频为空。'' ].
 self save: job
] ensure: [ recorder == active ifTrue: [ recorder := nil ] ]'.
service compile: 'send: command to: child
 child stdin nextPutAll: command; lf'.
service compile: 'controlRecording: id action: action
 | active state |
active := recorder.
(active isNil or: [ (active at: ''id'') ~= id ]) ifTrue: [ self error: ''录音已经结束。'' ].
state := action = ''pause'' ifTrue: [ ''paused'' ] ifFalse: [ ''recording'' ].
self send: action to: (active at: ''child'').
self waitUntil: [ (active at: ''state'') = state ] for: 5.
^ self idReceipt: id'.
service compile: 'stopRecording: id
 | active job recordId |
recordId := id.
active := recorder.
active ifNotNil: [
 (id notNil and: [ id ~= (active at: ''id'') ]) ifTrue: [ self error: ''录音已经结束。'' ].
 recordId := active at: ''id''.
 (active at: ''state'') = ''finishing'' ifFalse: [
  [ self send: ''stop'' to: (active at: ''child'') ] on: Error do: [ :error | nil ] ].
 [ self waitUntil: [ recorder ~~ active ] for: 5 ] on: Error do: [ :error |
  (active at: ''state'') = ''finishing'' ifFalse: [ (active at: ''child'') terminate ].
  self waitUntil: [ recorder ~~ active ] for: 20 ] ].
recordId ifNil: [ ^ Dictionary new ].
job := self job: recordId.
^ (self idReceipt: recordId) at: ''state'' put: (job at: ''state'');
 at: ''error'' put: (job at: ''error'' ifAbsent: [ nil ]); yourself'.
service compile: 'cancelRecording: id
 | job |
job := self job: id.
(recorder notNil and: [ (recorder at: ''id'') = id ]) ifTrue: [ self stopRecording: id ].
((job at: ''source'' ifAbsent: [ nil ]) = ''microphone'' and: [
 (job includesKey: ''messageId'') not and: [ #(''draft'' ''failed'') includes: (job at: ''state'') ] ])
 ifFalse: [ self error: ''此录音无法取消。'' ].
 self discardDraft: job.
 ^ self idReceipt: id'.
service compile: 'discardDraft: job
 | id |
 id := job at: ''id''.
(self fileFor: job named: (job at: ''original'')) ensureDelete.
(self fileFor: job named: ''message.json'') ensureDelete.
(directory / id) ensureDelete.
jobs removeKey: id'.
service compile: 'import: path
 | source seconds extension job |
source := path asFileReference.
seconds := self probe: source.
extension := source extension asLowercase.
(extension isNotEmpty and: [ extension size <= 8 and: [
 extension allSatisfy: [ :c | ''abcdefghijklmnopqrstuvwxyz0123456789'' includes: c ] ] ])
 ifFalse: [ self error: ''不支持的音频文件名。'' ].
job := self makeJob: source basename original: ''original.'', extension.
[
 source copyTo: (self fileFor: job named: (job at: ''original'')).
 job at: ''duration'' put: seconds.
 self save: job
] on: Error do: [ :error | self discardDraft: job. error pass ].
^ self idReceipt: (job at: ''id'')'.
service compile: 'pick
 | chosen |
chosen := (LMPlatformTools run: host arguments: #(''pick'') timeout: 600) trimBoth.
^ chosen ifEmpty: [ Dictionary new ] ifNotEmpty: [ self import: chosen ]'.
service compile: 'play: id
 | job target child active |
recorder ifNotNil: [ self error: ''请先停止录音再试听。'' ].
self stopPlayback.
job := self job: id.
target := (job at: ''source'' ifAbsent: [ nil ]) = ''microphone''
 ifTrue: [ self fileFor: job named: (job at: ''original'') ]
 ifFalse: [ self convert: job named: ''preview.wav'' format: ''wav'' ].
child := LMPlatformTools interactive: host arguments: {''play''. target fullName}.
active := Dictionary new at: ''id'' put: id; at: ''child'' put: child; at: ''started'' put: false; yourself.
player := active.
active at: ''monitor'' put: ([
 [ self monitor: child lines: [ :line | line = ''playing'' ifTrue: [ active at: ''started'' put: true ] ] ]
  ensure: [ player == active ifTrue: [ player := nil ] ]
] fork).
[ self waitUntil: [ (active at: ''started'') or: [ player ~~ active ] ] for: 5.
 (active at: ''started'') ifFalse: [ self error: ''音频播放失败，请核对 Windows 输出设备。'' ].
 ^ self idReceipt: id
] on: Error do: [ :error |
 player == active ifTrue: [ self stopPlayback ].
 error pass ]'.
service compile: 'stopPlayback
 | active |
active := player.
player := nil.
active ifNotNil: [ [ self send: ''stop'' to: (active at: ''child'') ] on: Error do: [ :error | nil ] ].
^ Dictionary new'.
service compile: 'submit: id message: messageId
 | job |
job := self job: id.
(job at: ''state'') = ''recording'' ifTrue: [ self error: ''请先停止录音。'' ].
(job at: ''messageId'' ifAbsent: [ messageId ]) = messageId ifFalse: [ self error: ''此音频已发送。'' ].
job at: ''messageId'' put: messageId.
(job at: ''state'') = ''draft'' ifTrue: [ job at: ''state'' put: ''queued'' ].
self save: job.
^ Dictionary new'.
service compile: 'retry: id
 | job |
job := self job: id.
(operations includesKey: id) ifTrue: [ self error: ''录音正在处理。'' ].
(job at: ''state'') = ''unknown'' ifTrue: [ self error: ''上传结果不确定，请先在控制台核对订单；不会自动重传。'' ].
(job at: ''state'') = ''recording'' ifTrue: [ self error: ''请先停止录音。'' ].
(job at: ''state'') = ''completed'' ifFalse: [
 job at: ''state'' put: ((job includesKey: ''orderId'') ifTrue: [ ''processing'' ] ifFalse: [ ''queued'' ]);
  at: ''nextPoll'' put: 0; removeKey: ''error'' ifAbsent: [ ].
 self save: job ].
^ Dictionary new'.
service compile: 'milliseconds
 ^ DateAndTime now asUnixTime * 1000'.
service compile: 'transcribe: job
 | file result |
[
 provider configuration.
 job at: ''state'' put: ''preparing''; removeKey: ''error'' ifAbsent: [ ].
 self save: job.
 job at: ''duration'' put: (self probe: (self fileFor: job named: (job at: ''original''))).
 file := self convert: job named: ''transcription.flac'' format: ''flac''.
 self isCurrent ifFalse: [ ^ self ].
 job at: ''signatureRandom'' put: ((UUID new asString copyWithout: $-) first: 16);
  at: ''state'' put: ''uploading''.
 self save: job.
 result := provider upload: file signature: (job at: ''signatureRandom'').
 job at: ''orderId'' put: (result at: ''orderId''); at: ''state'' put: ''processing'';
  at: ''nextPoll'' put: self milliseconds + 2500.
 self save: job
] on: Error do: [ :error |
 self transcriptionError: error for: job.
 self save: job ]'.
service compile: 'transcriptionError: error for: job
 (error isKindOf: LMVoiceProviderError) ifTrue: [
 job at: ''state'' put: (error code = #uploadUnknown ifTrue: [ ''unknown'' ] ifFalse: [ ''failed'' ]);
  at: ''error'' put: error messageText.
 ^ self ].
(job at: ''state'') = ''uploading'' ifTrue: [
 job at: ''state'' put: ''unknown''; at: ''error'' put: ''上传结果不确定，请核对讯飞订单。''.
 ^ self ].
job at: ''state'' put: ''failed''; at: ''error'' put: ''音频预处理失败，请核对原音文件。'''.
service compile: 'query: job
 [
 [ | content order status silent data |
  content := provider query: (job at: ''orderId'') signature: (job at: ''signatureRandom'').
  self isCurrent ifFalse: [ ^ self ].
  LMPlatformTools writeJSON: content to: (self fileFor: job named: ''provider-result.json'').
  order := content at: ''orderInfo''.
  status := (order at: ''status'') asNumber.
  (#(0 3) includes: status) ifTrue: [ job removeKey: ''error'' ifAbsent: [ ]. ^ self ].
  silent := status = -1 and: [ (order at: ''failType'' ifAbsent: [ 0 ]) asNumber = 6 ].
  (status = 4 or: [ silent ]) ifFalse: [
   LMVoiceProviderError raise: #orderFailed message: ''讯飞未能完成此音频的转录。'' ].
  data := silent
   ifTrue: [ Dictionary new at: ''text'' put: ''''; at: ''segments'' put: #(); yourself ]
   ifFalse: [ provider parseTranscript: (content at: ''orderResult'') ].
  job at: ''transcript'' put: (data at: ''text''); at: ''segments'' put: (data at: ''segments'');
   at: ''state'' put: ''completed''; removeKey: ''error'' ifAbsent: [ ]
 ] on: Error do: [ :error |
  ((error isKindOf: LMVoiceProviderError) and: [ error code = #queryRetry ])
   ifTrue: [ job at: ''error'' put: error messageText ]
   ifFalse: [
    job at: ''state'' put: ''failed''; at: ''error'' put: ((error isKindOf: LMVoiceProviderError)
     ifTrue: [ error messageText ] ifFalse: [ ''查询转录结果失败。'' ]) ] ]
] ensure: [
 job at: ''nextPoll'' put: self milliseconds + 5000.
 self save: job ].
(job at: ''state'') = ''completed'' ifTrue: [ self wakeConversation ]'.
service compile: 'wakeConversation
 self isCurrent ifFalse: [ ^ self ].
((LoomConversation storageStatus at: ''phase'') = ''ready'') ifTrue: [ LoomConversation start ]'.
service compile: 'recoverQueuedMessages
 | revision |
((LoomConversation storageStatus at: ''phase'') = ''ready'') ifFalse: [ ^ self ].
revision := LoomConversation storageRevision.
revision = conversationRevision ifTrue: [ ^ self ].
(LoomConversation storage: ''audio-messages'') do: [ :message |
 | job |
 job := jobs at: (message at: ''audioId'') ifAbsent: [ nil ].
 (job notNil and: [ (job includesKey: ''messageId'') not ]) ifTrue: [
  self submit: (job at: ''id'') message: (message at: ''id'') ] ].
conversationRevision := revision'.
service compile: 'run: action on: job
 | id process |
id := job at: ''id''.
(operations includesKey: id) ifTrue: [ ^ self ].
process := [ [ self perform: action with: job ] ensure: [ operations removeKey: id ifAbsent: [ ] ] ] newProcess.
operations at: id put: process.
process resume'.
service compile: 'tick
 self recoverQueuedMessages.
jobs values do: [ :job |
 | state |
 state := job at: ''state''.
 state = ''queued'' ifTrue: [ self run: #transcribe: on: job ].
 (state = ''processing'' and: [ self milliseconds >= (job at: ''nextPoll'' ifAbsent: [ 0 ]) ])
  ifTrue: [ self run: #query: on: job ] ]'.
service compile: 'start
 (poller notNil and: [ poller isTerminated not ]) ifTrue: [ ^ self ].
poller := [
 [ self isCurrent and: [ closed not ] ] whileTrue: [
  [ self tick ] on: Error do: [ :error |
   Smalltalk globals at: #LMVoiceLastReadError put: error messageText ].
  (Delay forMilliseconds: 200) wait ]
] fork.
poller name: ''Loom GT audio queue'''.
service compile: 'close
 closed := true.
control critical: [
 [ self stopRecording: nil ] ensure: [ self stopPlayback ] ]'.
service compile: 'retire
 closed := true.
poller ifNotNil: [ poller terminate ].
operations values do: #terminate.
recorder ifNotNil: [ (recorder at: ''monitor'') terminate ].
player ifNotNil: [ (player at: ''monitor'') terminate ].
recorder := nil. player := nil'.
service compile: 'execute: action options: options
 | id |
id := options at: ''audioId'' ifAbsent: [ nil ].
^ control critical: [
 closed ifTrue: [ self error: ''录音服务正在退出。'' ].
 action = ''record'' ifTrue: [ ^ self record ].
 action = ''stop'' ifTrue: [ ^ self stopRecording: id ].
 (#(''pause'' ''resume'') includes: action) ifTrue: [ ^ self controlRecording: id action: action ].
 action = ''cancel'' ifTrue: [ ^ self cancelRecording: id ].
 action = ''import'' ifTrue: [ ^ self import: (options at: ''file'') ].
 action = ''pick'' ifTrue: [ ^ self pick ].
 action = ''play'' ifTrue: [ ^ self play: id ].
 action = ''stop-playback'' ifTrue: [ ^ self stopPlayback ].
 action = ''retry'' ifTrue: [ ^ self retry: id ].
 action = ''submit'' ifTrue: [ ^ self submit: id message: (options at: ''messageId'') ].
 action = ''close-window'' ifTrue: [ self stopRecording: nil. ^ self stopPlayback ].
 self error: ''未知音频操作。'' ]'.
'GT audio queue installed'
