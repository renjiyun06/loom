"The recording controls submit the finished audio through the conversation model."
| controls |
controls := (Object << #LMVoiceComposer
 slots: #(owner view entry strip toggle cancel confirm bars phase audioId pending closed poller meterQueued);
 package: 'Loom-Interface') install.
controls compile: 'buildFor: conversationView
 | left right |
 owner := conversationView.
 phase := #idle. pending := false. closed := false. meterQueued := false.
 view := BrHorizontalPane new hFitContent; vExact: 28; alignCenterLeft;
  margin: (BlInsets left: 5); yourself.
 entry := LMChatStyle replyAction: #recordVoice icon: ''mic'' action: [ self start ].
 entry label: ''开始录音''.
 strip := BrHorizontalPane new id: #recordingStrip; hFitContent; vExact: 28; alignCenter;
  padding: (BlInsets left: 3 right: 3);
  border: (BlBorder paint: (Color gray: 0.86) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 5); yourself.
 strip layout cellSpacing: 3.
 bars := OrderedCollection new.
 left := self waveform.
 right := self waveform.
 cancel := LMChatStyle replyAction: #cancelVoice icon: ''x'' action: [ self finish: ''cancel'' ].
 cancel label: ''取消录音''.
 toggle := LMChatStyle replyAction: #toggleVoice icon: ''pause'' action: [ self toggle ].
 confirm := LMChatStyle replyAction: #confirmVoice icon: ''check'' action: [ self finish: ''confirm'' ].
 confirm label: ''发送录音''.
 strip addChildren: { cancel. left. toggle. right. confirm }.
 view addChildren: { strip. entry }.
 self refreshControls.
 ^ view'.
controls compile: 'waveform
 | pane bar |
 pane := BrHorizontalPane new hFitContent; vExact: 22; alignCenter; yourself.
 pane layout cellSpacing: 2.
 12 timesRepeat: [
  bar := BlElement new background: (Color gray: 0.62);
   geometry: (BlRoundedRectangleGeometry cornerRadius: 1);
   constraintsDo: [ :c | c horizontal exact: 2. c vertical exact: 3 ]; yourself.
  bars add: bar. pane addChild: bar ].
 ^ pane'.
controls compile: 'displayLevels: levels
 | offset |
 offset := bars size - levels size.
 bars withIndexDo: [ :bar :index |
  | height level |
  level := index <= offset ifTrue: [ 0 ] ifFalse: [ levels at: index - offset ].
  height := (3 + (level * 0.17)) rounded.
  bar constraints vertical resizer size = height ifFalse: [
   bar constraintsDo: [ :c | c vertical exact: height ] ] ]'.
controls compile: 'refreshControls
 | available icon |
 entry visibility: (phase = #idle ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ]).
 strip visibility: (phase = #idle ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]).
 available := pending not and: [ audioId notNil ].
 cancel enabled: available. toggle enabled: (available and: [ phase ~= #draft ]).
 self updateSendAvailability.
 icon := LMIcons iconNamed: (phase = #paused ifTrue: [ ''play'' ] ifFalse: [ ''pause'' ]).
 icon constraintsDo: [ :c | c frame horizontal alignCenter. c frame vertical alignCenter ].
 toggle removeChildren; addChild: icon.
 toggle label: (phase = #paused ifTrue: [ ''继续录音'' ] ifFalse: [ ''暂停录音'' ])'.
controls compile: 'isBusy ^ pending = true'.
controls compile: 'updateSendAvailability
 | allowed |
 allowed := self isBusy not and: [ audioId notNil and: [ owner canSendMessage ] ].
 confirm states isEnabled = allowed ifFalse: [ confirm enabled: allowed ]'.
controls compile: 'start
 (closed or: [ pending or: [ phase ~= #idle ] ]) ifTrue: [ ^ self ].
 phase := #starting.
 self displayLevels: #().
 owner voiceNotice: nil.
 self run: ''record'' then: [ :reply |
  audioId := reply at: ''audioId''.
  phase := #recording.
  self startMeter ]'.
controls compile: 'toggle
 | action next |
 phase = #paused
  ifTrue: [ action := ''resume''. next := #recording ]
  ifFalse: [ action := ''pause''. next := #paused ].
 self run: action then: [ :reply | phase := next ]'.
controls compile: 'finish: action
 self run: action then: [ :reply |
  self reset.
  owner voiceNotice: nil ]'.
controls compile: 'sendRecording: id
 | stopped |
 stopped := self request: ''stop'' for: id.
 (stopped at: ''ok'') ifFalse: [ ^ stopped ].
 (stopped at: ''state'') = ''draft'' ifFalse: [
  self error: (stopped at: ''error'' ifAbsent: [ ''无法保存录音'' ]) ].
 [ LoomConversation submitAudio: id text: '''' ] on: Error do: [ :error |
  stopped at: ''ok'' put: false; at: ''error'' put: error messageText ].
 ^ stopped'.
controls compile: 'request: action for: id
 | options |
 options := Dictionary new.
 id ifNotNil: [ options at: ''audioId'' put: id ].
 ^ LMVoice await: (LMVoice request: action options: options)'.
controls compile: 'run: action then: success
 | id |
 (closed or: [ pending or: [ action ~= ''record'' and: [ audioId isNil ] ] ]) ifTrue: [ ^ self ].
 (action = ''confirm'' and: [ owner canSendMessage not ]) ifTrue: [ ^ self ].
 id := audioId. pending := true. self refreshControls.
 owner updateSendAvailability.
 [ | reply |
  reply := [ action = ''confirm''
   ifTrue: [ self sendRecording: id ] ifFalse: [ self request: action for: id ] ] on: Error do: [ :error |
   Dictionary new at: ''ok'' put: false; at: ''error'' put: error messageText; yourself ].
  (closed or: [ owner hostWorld isNil ])
   ifTrue: [ (#(''record'' ''pause'' ''resume'') includes: action) ifTrue: [
    self stopDetached: (reply at: ''audioId'' ifAbsent: [ id ]) ] ]
   ifFalse: [ owner defer: [
    pending := false.
    closed ifTrue: [ (#(''record'' ''pause'' ''resume'') includes: action) ifTrue: [
     self stopDetached: (reply at: ''audioId'' ifAbsent: [ id ]) ] ] ifFalse: [
     (reply at: ''ok'') ifTrue: [ success value: reply ] ifFalse: [
      (#(''record'' ''confirm'') includes: action) ifTrue: [
       (action = ''confirm'' and: [ (reply at: ''state'' ifAbsent: [ nil ]) = ''draft'' ])
        ifTrue: [ phase := #draft. poller ifNotNil: [ poller terminate. poller := nil ] ]
        ifFalse: [ self reset ] ].
      owner voiceNotice: (reply at: ''error'') ].
     self refreshControls.
     owner updateSendAvailability ] ] ]
 ] fork'.
controls compile: 'startMeter
 | recording |
 recording := audioId.
 poller := [ | previous |
  [ closed not and: [ audioId = recording ] ] whileTrue: [
   meterQueued ifFalse: [ | snapshot |
    snapshot := LMVoice meter.
    (snapshot notNil and: [ snapshot ~= previous or: [
     pending not and: [ (snapshot at: ''audioId'') ~= recording ] ] ]) ifTrue: [
     previous := snapshot. meterQueued := true.
     owner defer: [
      [ (closed not and: [ audioId = recording ]) ifTrue: [
       (snapshot at: ''audioId'') = recording
        ifTrue: [ self displayLevels: (snapshot at: ''levels'') ]
        ifFalse: [ pending ifFalse: [
         self reset. self refreshControls.
         owner voiceNotice: ''录音已结束'' ] ] ] ] ensure: [ meterQueued := false ] ] ] ].
   (Delay forMilliseconds: 100) wait ]
 ] fork.
 poller name: ''Loom microphone meter'''.
controls compile: 'reset
 audioId := nil. phase := #idle.
 poller ifNotNil: [ poller terminate. poller := nil ].
 meterQueued := false'.
controls compile: 'isClosed ^ closed'.
controls compile: 'stopDetached: id
 id ifNotNil: [ [ [ self request: ''stop'' for: id ] on: Error do: [ :error | nil ] ] fork ]'.
controls compile: 'close
 closed := true.
 pending ifFalse: [ self stopDetached: audioId ].
 self reset'.
'Loom voice controls installed'
