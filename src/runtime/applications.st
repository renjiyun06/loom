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
 ((Smalltalk globals at: #LoomApplicationSession ifAbsent: [ nil ]) = BridgeRuntimeSessionId)
  ifFalse: [ ^ Dictionary new at: ''phase'' put: ''starting''; yourself ].
 ^ self statuses at: name ifAbsent: [ Dictionary new at: ''phase'' put: ''starting''; yourself ]'.
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
 (Smalltalk globals at: #LMVoice ifAbsent: [ nil ]) ifNotNil: [ :voice |
  (voice respondsTo: #retireRequests) ifTrue: [ voice retireRequests ] ].
 Smalltalk globals removeKey: #LoomConversationStore ifAbsent: [ ].
 Smalltalk globals at: #LoomApplicationStatuses put: Dictionary new.
 Smalltalk globals at: #LoomApplicationLoadMutex put: Mutex new.
 Smalltalk globals at: #LoomApplicationSession put: BridgeRuntimeSessionId'.
applications class compile: 'prepareShutdown
 (Smalltalk globals at: #LoomGtVoice ifAbsent: [ nil ]) ifNotNil: #close'.
applications class compile: 'start
 | mutex gui |
 ((Smalltalk globals at: #LoomApplicationSession ifAbsent: [ nil ]) = BridgeRuntimeSessionId)
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
    self load: ''conversation-components.st''.
    self load: ''conversation-ui.st'' ].
   ((self statusFor: ''conversation'') at: ''phase'') = ''ready'' ifTrue: [ LoomConversation start ] ]
  ifFalse: [ self statuses at: ''conversation'' put: (self statusFor: ''conversation-model'') ].
 gui ifTrue: [
  self attempt: ''session-view'' during: [
   (Smalltalk globals includesKey: #LMSessionManagerUI)
    ifFalse: [ self load: ''loom-session-ui.st'' ] ].
  self attempt: ''activity-view'' during: [
   (Smalltalk globals includesKey: #LMActivityOverviewUI)
    ifFalse: [ self load: ''loom-activity-ui.st'' ] ] ].
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
  manager := LMGtVoice new initializeAt: ExperimentRoot forSession: BridgeRuntimeSessionId; yourself.
  Smalltalk globals at: #LoomGtVoice put: manager ].
 manager start'.
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
 (contents userData at: #loomDesktopSession ifAbsent: [ nil ]) = BridgeRuntimeSessionId ifTrue: [ ^ self ].
 contents childWithId: GtWorldShutdownPromptId
  ifFound: [ :prompt | prompt removeFromParent ] ifNone: [ ].
 contents userData at: #loomDesktopSession put: BridgeRuntimeSessionId'.
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
