"Load, hot-reload, and restore Loom's applications inside GT."
| applications |
applications := (Object << #LoomApplications slots: #(); package: 'Loom-Application') install.
applications class compile: 'load: name
 | file loader |
 loader := Smalltalk globals at: #LoomRuntimeSourceLoader ifAbsent: [ nil ].
 loader ifNotNil: [ ^ loader value: name ].
 file := ExperimentRoot / ''src'' / ''runtime'' / name.
 ^ Smalltalk compiler evaluate: (String cr join: file contents lines)'.
applications class compile: 'statuses
 ^ Smalltalk globals at: #LoomApplicationStatuses ifAbsentPut: [ Dictionary new ]'.
applications class compile: 'statusFor: name
 ((Smalltalk globals at: #LoomApplicationSession ifAbsent: [ nil ]) = LoomRuntimeSessionId)
  ifFalse: [ ^ Dictionary new at: ''phase'' put: ''starting''; yourself ].
 ^ self statuses at: name ifAbsent: [ Dictionary new at: ''phase'' put: ''starting''; yourself ]'.
applications class compile: 'replyContextFor: message from: source
 | context sources threadId mailDatabase |
 mailDatabase := ExperimentRoot / ''state'' / ''mail'' / ''mail.sqlite''.
 sources := Dictionary new
  at: ''mail'' put: (''要查邮件往来时，如果本次调用带有 threadId，用该值通过 runtime_eval 调用 LoomGtMail threadHistory:。如果只有邮件主题、时间或关键词，可以只读查询 '', mailDatabase fullName, '' 的 mail_messages 表。'');
  at: ''conversation'' put: ''要查用户以前在 GT 界面说过什么，通过 runtime_eval 读取 LoomConversation records。找到语音消息后，用消息 ID 调用 LoomConversation speechCorrectionAt: 获取纠正稿。'';
  yourself.
 (Smalltalk globals includesKey: #LoomGtWeixin) ifTrue: [
  sources at: ''weixin'' put: ''要查近期微信对话，通过 runtime_eval 读取 LoomGtWeixin recentHistory。'' ].
 context := Dictionary new
  at: ''source'' put: source;
  at: ''messageId'' put: (message at: ''id'');
  at: ''historyLookupInstructions'' put: ''给处理当前消息的 Codex。当前消息提到以前的约定，而你缺少相关前文时，可以按需查询下面的历史来源。'';
  at: ''historySources'' put: sources;
  yourself.
 threadId := message at: ''threadId'' ifAbsent: [ nil ].
 threadId ifNotNil: [ context at: ''threadId'' put: threadId ].
 ^ context'.
applications class compile: 'attempt: name during: operation
 ^ [ operation value.
     self statuses at: name put: (Dictionary new at: ''phase'' put: ''ready''; yourself).
     true
   ] on: Error do: [ :error |
    self statuses at: name put: (Dictionary new at: ''phase'' put: ''failed''; at: ''error'' put: error messageText;
     at: ''errorAt'' put: error signalerContext printString; yourself).
    false ]'.
applications class compile: 'resetAfterRuntimeRestart
 (Smalltalk globals removeKey: #LoomGtVoice ifAbsent: [ nil ]) ifNotNil: #retire.
 (Smalltalk globals removeKey: #LoomGtMail ifAbsent: [ nil ]) ifNotNil: #retire.
 (Smalltalk globals removeKey: #LoomGtWeixin ifAbsent: [ nil ]) ifNotNil: #retire.
 (Smalltalk globals at: #LMVoice ifAbsent: [ nil ]) ifNotNil: [ :voice |
  (voice respondsTo: #retireRequests) ifTrue: [ voice retireRequests ] ].
 Smalltalk globals removeKey: #LoomConversationStore ifAbsent: [ ].
 Smalltalk globals at: #LoomApplicationStatuses put: Dictionary new.
 Smalltalk globals at: #LoomApplicationLoadMutex put: Mutex new.
 Smalltalk globals at: #LoomApplicationSession put: LoomRuntimeSessionId'.
applications class compile: 'prepareShutdown
 (Smalltalk globals at: #LoomGtMail ifAbsent: [ nil ]) ifNotNil: #close.
 (Smalltalk globals at: #LoomGtWeixin ifAbsent: [ nil ]) ifNotNil: #close.
 (Smalltalk globals at: #LoomGtVoice ifAbsent: [ nil ]) ifNotNil: #close'.
applications class compile: 'start
 | mutex gui |
 ((Smalltalk globals at: #LoomApplicationSession ifAbsent: [ nil ]) = LoomRuntimeSessionId)
  ifFalse: [ self resetAfterRuntimeRestart ].
 mutex := Smalltalk globals at: #LoomApplicationLoadMutex ifAbsentPut: [ Mutex new ].
 gui := Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ].
 mutex critical: [
  self install.
  gui ifTrue: [ self openDesktopRequest: nil restore: true ] ]'.
applications class compile: 'reload
 self statuses keysAndValuesDo: [ :name :status |
  (status at: ''phase'') = ''failed'' ifTrue: [
   self statuses at: name put: (Dictionary new at: ''phase'' put: ''starting''; yourself) ] ].
 ^ [ self start ] fork'.
applications class compile: 'install
 | gui modelLoaded |
 gui := Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ].
 self attempt: ''desktop-renderer'' during: [ self load: ''desktop-compat.st'' ].
 self attempt: ''desktop-ime'' during: [ self load: ''windows-ime.st'' ].
 self attempt: ''platform-tools'' during: [ self load: ''platform-tools.st'' ].
 modelLoaded := self attempt: ''conversation-model'' during: [
  self load: ''conversation-db.st''.
  self load: ''conversation.st''.
  self load: ''upgrade-main-session.st''.
  self load: ''voice.st'' ].
 modelLoaded
  ifTrue: [
   self attempt: ''conversation'' during: [ self initializeConversationStorage ].
   self attempt: ''voice'' during: [ self initializeVoice ].
   self attempt: ''conversation-view'' during: [
    self load: ''conversation-stream.st''.
    self load: ''activity-timeline.st''.
    self load: ''conversation-components.st''.
    self load: ''conversation-ui.st'' ].
   ((self statusFor: ''conversation'') at: ''phase'') = ''ready'' ifTrue: [ LoomConversation start ] ]
  ifFalse: [ self statuses at: ''conversation'' put: (self statusFor: ''conversation-model'') ].
 self initializeMail.
 self initializeWeixin.
 gui ifTrue: [
  self attempt: ''session-view'' during: [ self load: ''loom-session-ui.st'' ].
  self attempt: ''activity-view'' during: [ self load: ''loom-activity-ui.st'' ] ].
 ^ self statuses copy'.
applications class compile: 'initializeConversationStorage
 | store |
 store := Smalltalk globals at: #LoomConversationStore ifAbsent: [ nil ].
 store ifNil: [
  store := LMConversationStore new directory: LoomConversation directory; yourself ].
 store initializeStorage.
 Smalltalk globals at: #LoomConversationStore put: store'.
applications class compile: 'initializeVoice
 | manager |
 self load: ''xfyun.st''.
 self load: ''voice-service.st''.
 manager := Smalltalk globals at: #LoomGtVoice ifAbsent: [ nil ].
 (manager isNil or: [ manager isClosed ]) ifTrue: [
  manager := LMGtVoice new initializeAt: ExperimentRoot forSession: LoomRuntimeSessionId; yourself.
  Smalltalk globals at: #LoomGtVoice put: manager ].
 manager start'.
applications class compile: 'initializeMail
 | config manager |
 config := ExperimentRoot / ''config'' / ''mail.local.json''.
 config exists ifFalse: [
  ^ self statuses at: ''mail'' put: (Dictionary new at: ''phase'' put: ''disabled''; yourself) ].
 self attempt: ''mail'' during: [
  self load: ''mail.st''.
  manager := Smalltalk globals at: #LoomGtMail ifAbsent: [ nil ].
  (manager isNil or: [ manager isClosed ]) ifTrue: [
   manager := LMGtMail new initializeAt: ExperimentRoot config: config; yourself.
   Smalltalk globals at: #LoomGtMail put: manager ].
  manager start ]'.
applications class compile: 'initializeWeixin
 | config manager |
 config := ExperimentRoot / ''config'' / ''weixin.local.json''.
 config exists ifFalse: [
  ^ self statuses at: ''weixin'' put: (Dictionary new at: ''phase'' put: ''disabled''; yourself) ].
 self attempt: ''weixin'' during: [
  self load: ''weixin.st''.
  manager := Smalltalk globals at: #LoomGtWeixin ifAbsent: [ nil ].
  (manager isNil or: [ manager isClosed ]) ifTrue: [
   manager := (Smalltalk globals at: #LMGtWeixin) new initializeAt: ExperimentRoot config: config; yourself.
   manager start.
   Smalltalk globals at: #LoomGtWeixin put: manager ] ]'.
applications class compile: 'restoreIn: world
 self dismissRestoredShutdownPromptIn: world.
 self attempt: ''desktop-toolbar'' during: [ (world instVarNamed: #worldElement) updateToolbarActions ].
 self attempt: ''conversation-window'' during: [
  (Smalltalk globals at: #LoomConversationWindow ifAbsent: [ nil ]) ifNotNil: [ :view | view restore ] ].
 self attempt: ''session-window'' during: [
  (Smalltalk globals at: #LoomSessionManagerWindow ifAbsent: [ nil ]) ifNotNil: [ :view | view restoreIn: world ] ].
 self attempt: ''activity-window'' during: [
  (Smalltalk globals at: #LoomActivityOverviewWindow ifAbsent: [ nil ]) ifNotNil: [ :view | view restoreIn: world ] ]'.
applications class compile: 'dismissRestoredShutdownPromptIn: world
 | contents |
 contents := world instVarNamed: #worldElement.
 (contents userData at: #loomDesktopSession ifAbsent: [ nil ]) = LoomRuntimeSessionId ifTrue: [ ^ self ].
 contents childWithId: GtWorldShutdownPromptId
  ifFound: [ :prompt | prompt removeFromParent ] ifNone: [ ].
 contents userData at: #loomDesktopSession put: LoomRuntimeSessionId'.
applications class compile: 'openDesktopRequest: id restore: restore
 | universe request |
 (Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ]) ifFalse: [ self error: ''The runtime is not in desktop mode'' ].
 request := Dictionary new.
 id ifNotNil: [
  (Smalltalk globals at: #LoomDesktopRequests ifAbsentPut: [ Dictionary new ]) at: id put: request ].
 universe := BlParallelUniverse forHost: BlWinitHost.
 universe defer: [
  [ | worlds world |
   worlds := GtWorld allOpenWorlds select: [ :each | each host isKindOf: BlWinitHost ].
   world := worlds ifEmpty: [ Smalltalk globals at: #LoomDesktopWorld ifAbsent: [ nil ] ] ifNotEmpty: [ worlds first ].
   world ifNil: [ world := GtWorld openDefault ] ifNotNil: [ world isOpened ifFalse: [ world show ] ].
   Smalltalk globals at: #LoomDesktopWorld put: world.
   GtWorld defaultId: world id.
   request at: ''world'' put: world.
   world requestNextPulse.
   restore ifTrue: [ self restoreIn: world ]
  ] on: Error do: [ :error |
   request at: ''error'' put: error messageText.
   self statuses at: ''desktop'' put: (Dictionary new at: ''phase'' put: ''failed''; at: ''error'' put: error messageText; yourself) ] ].
 universe hasUIProcess ifFalse: [ universe startUniverse ]'.
applications
