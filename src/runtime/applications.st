"Install and restore the applications of this Loom image."
| applications |
applications := (Object << #LoomApplications slots: #(); package: 'Loom-Application') install.
Smalltalk globals at: #LoomApplicationErrors put: Dictionary new.
applications class compile: 'load: name
 | file |
 file := ExperimentRoot / ''src'' / ''runtime'' / name.
 ^ Smalltalk compiler evaluate: (String cr join: file contents lines)'.
applications class compile: 'attempt: name during: operation
 ^ [ operation value. true ] on: Error do: [ :error |
  LoomApplicationErrors at: name put: error messageText. false ]'.
applications class compile: 'statusFor: name
 | status starting |
 starting := Dictionary new at: ''phase'' put: ''starting''; yourself.
 status := [
  STONJSON fromString: (BridgeIPC / ''application-status.json'') contents
 ] on: Error do: [ :error | ^ starting ].
 (status at: ''session'' ifAbsent: [ nil ]) = BridgeRuntimeSessionId ifFalse: [ ^ starting ].
 (status at: ''phase'') = ''failed'' ifTrue: [ ^ status ].
 ^ status at: name ifAbsent: [ starting ]'.
applications class compile: 'reload
 | request temporary |
 request := BridgeIPC / ''application-reload.json''.
 request exists ifTrue: [ ^ self ].
 temporary := BridgeIPC / (UUID new asString, ''.reload.tmp'').
 [
  temporary writeStreamDo: [ :stream |
   stream nextPutAll: (STONJSON toString: (Dictionary new at: ''session'' put: BridgeRuntimeSessionId; yourself)) ].
  [ temporary copy renameTo: request basename ] on: Error do: [ :error |
   request exists ifFalse: [ error pass ] ]
 ] ensure: [ temporary ensureDelete ]'.
applications class compile: 'install
 | gui conversationVersion voiceVersion uiVersion |
 gui := Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ].
 self attempt: ''desktop-renderer'' during: [ self load: ''desktop-compat.st'' ].
 self attempt: ''desktop-ime'' during: [ self load: ''windows-ime.st'' ].
 self attempt: ''conversation'' during: [
  conversationVersion := (Smalltalk globals at: #LMConversation ifAbsent: [ nil ])
   ifNil: [ 0 ] ifNotNil: [ :class | class bootstrapVersion ].
  conversationVersion < 3 ifTrue: [ self load: ''conversation.st'' ].
  self load: ''upgrade-main-session.st''.
  voiceVersion := (Smalltalk globals at: #LMVoice ifAbsent: [ nil ])
   ifNil: [ 0 ] ifNotNil: [ :class | class featureVersion ].
  (voiceVersion < 5 or: [ conversationVersion < 3 ]) ifTrue: [ self load: ''voice.st'' ].
  uiVersion := (Smalltalk globals at: #LMConversationUI ifAbsent: [ nil ])
   ifNil: [ 0 ] ifNotNil: [ :class | class featureVersion ].
  uiVersion < 24 ifTrue: [ self load: ''conversation-ui.st'' ] ].
 gui ifTrue: [
  self attempt: ''session-view'' during: [
   (Smalltalk globals includesKey: #LMSessionManagerUI)
    ifFalse: [ self load: ''loom-session-ui.st'' ] ].
  self attempt: ''activity-view'' during: [
   (Smalltalk globals includesKey: #LMActivityOverviewUI)
    ifFalse: [ self load: ''loom-activity-ui.st'' ] ] ].
 ^ LoomApplicationErrors copy'.
applications class compile: 'restoreIn: world
 self attempt: ''desktop-toolbar'' during: [ (world instVarNamed: #worldElement) updateToolbarActions ].
 self attempt: ''conversation-window'' during: [
  (Smalltalk globals at: #LoomConversationWindow ifAbsent: [ nil ]) ifNotNil: [ :view | view restore ] ].
 self attempt: ''session-window'' during: [
  (Smalltalk globals at: #LoomSessionManagerWindow ifAbsent: [ nil ]) ifNotNil: [ :view | view restoreIn: world ] ].
 self attempt: ''activity-window'' during: [
  (Smalltalk globals at: #LoomActivityOverviewWindow ifAbsent: [ nil ]) ifNotNil: [ :view | view restoreIn: world ] ]'.
applications install
