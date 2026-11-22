"Compact monochrome conversation in the existing GT native tab."
| ui slots previousSlots oldClass oldView textRunRenderer |
"Skia returns a null text blob when the text run contains no glyphs."
textRunRenderer := (SkiaTextPainter >> #fillTextRun:withColor:strokeColor:) sourceCode.
(textRunRenderer includesSubstring: 'aTextRun glyphs isEmpty') ifFalse: [
 SkiaTextPainter compile: textRunRenderer lines first , String cr ,
  ' aTextRun glyphs isEmpty ifTrue: [ ^ self ].' , String cr ,
  (String cr join: textRunRenderer lines allButFirst) ].
((Smalltalk globals includesKey: #LMConversationStream) and: [
 (Smalltalk globals at: #LMConversationStream) includesSelector: #visibleActivities ])
 ifFalse: [ Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'conversation-stream.st') contents ].
((Smalltalk globals includesKey: #LMActivityReader) and: [
 (Smalltalk globals at: #LMActivityReader) includesSelector: #pageOf:focus:session: ])
 ifFalse: [ Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'activity-timeline.st') contents ].
((Smalltalk globals includesKey: #LMConversationMessageView) and: [
 (Smalltalk globals at: #LMConversationMessageView) includesSelector: #renderRecording: ])
 ifFalse: [ Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'conversation-components.st') contents ].
Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'conversation-voice.st') contents.
slots := #(#space #history #input #status #poller #lastText #errorText #root #layoutVersion #activity #lastActivity #recordCache #recordKey #refreshQueued #followOutput #followButton #refreshGeneration #historyItems #activityItems #activityPane #bodyPane #splitterElement #activityWidth #activityHidden #activityFollow #stopButton #lastPayload #pendingAnchor #activityExpansionStates #activityDetailModes #messageSourceStates #composerPane #placeholderLabel #sessionLabel #conversationPane #voiceComposer #voicePlaybackPending).
oldClass := Smalltalk globals at: #LMConversationUI ifAbsent: [ nil ].
oldView := Smalltalk globals at: #LoomConversationWindow ifAbsent: [ nil ].
oldView ifNotNil: [ oldView stopRefreshing ].
previousSlots := oldClass ifNil: [ #() ] ifNotNil: [ oldClass instVarNames collect: #asSymbol ].
ui := (Object << #LMConversationUI slots: ((previousSlots reject: [ :each | slots includes: each ]), slots); package: 'Loom-Interface') install.
ui compile: 'activityDetailMode: value for: id
 activityDetailModes ifNil: [ activityDetailModes := Dictionary new ].
 activityDetailModes at: id put: value'.
ui compile: 'activityDetailModeFor: id
 activityDetailModes ifNil: [ activityDetailModes := Dictionary new ].
 ^ activityDetailModes at: id ifAbsent: [ #arguments ]'.
ui compile: 'activityExpanded: value for: id
 activityExpansionStates ifNil: [ activityExpansionStates := Dictionary new ].
 activityExpansionStates at: id put: value'.
ui compile: 'activityExpandedFor: id
 activityExpansionStates ifNil: [ activityExpansionStates := Dictionary new ].
 ^ activityExpansionStates at: id ifAbsent: [ false ]'.
ui compile: 'applyUpdate: payload
 | messagesChanged activityChanged anchor anchorIndex firstUpdate incomingActivities activityAnchor prefix |
 layoutVersion = 7 ifFalse: [ ^ self ].
 firstUpdate := lastPayload isNil.
 lastPayload := payload.
 messagesChanged := self syncList: history collection: historyItems with: (payload at: ''messages'').
 incomingActivities := payload at: ''activities''.
 (activityFollow not and: [ activityItems notEmpty and: [ incomingActivities notEmpty and: [
  (activityItems first at: ''id'') ~= (incomingActivities first at: ''id'') ] ] ]) ifTrue: [
   activityAnchor := self listAnchor: activity with: activityItems.
   prefix := incomingActivities findFirst: [ :entry | (entry at: ''id'') = (activityItems first at: ''id'') ].
   prefix > 1 ifTrue: [
    activityItems addAllFirst: (incomingActivities first: prefix - 1).
    (activity childNamed: #scrollable) dataSource notifyItemsInserted: (1 to: prefix - 1) ] ].
 activityChanged := self syncList: activity collection: activityItems with: incomingActivities.
 status text: (errorText ifNil: [
  (#(''等待消息'' ''已完成'') includes: (payload at: ''status''))
   ifTrue: [ ''Enter 发送 · Shift Enter 换行'' ] ifFalse: [ payload at: ''status'' ] ]).
 stopButton visibility: ((payload at: ''processing'') ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ]).
 self updateActivityEmpty.
 (messagesChanged and: [ followOutput not and: [ firstUpdate not ] ]) ifTrue: [
  history userData at: #newContent put: true. self updateFollowButton ].
 pendingAnchor
  ifNotNil: [
   anchor := pendingAnchor. pendingAnchor := nil.
   anchorIndex := historyItems findFirst: [ :entry | (entry at: ''id'') = anchor first ].
   anchorIndex > 0 ifTrue: [ self defer: [ history scrollToIndex: anchorIndex offset: anchor second ] ] ]
  ifNil: [ (messagesChanged and: [ followOutput ]) ifTrue: [ self defer: [ self followLatest ] ] ].
 activityAnchor ifNotNil: [
  self restoreActivityAnchor: activityAnchor ].
 (activityChanged and: [ activityFollow ]) ifTrue: [ self defer: [ self followActivities ] ]'.
ui compile: 'bindActivityRow: row item: value
 ^ [ row descriptor: value ] on: Error do: [ :error | row showRenderingError: error descriptor: value ]'.
ui compile: 'bindMessageRow: row item: value
 ^ [ row descriptor: value ] on: Error do: [ :error | row showRenderingError: error descriptor: value ]'.
ui compile: 'build
 | body left composer footer draft splitter divider anchor historyFrame inputInset activityLimit |
 voiceComposer ifNotNil: [ voiceComposer close ].
 anchor := self historyAnchor.
 draft := input ifNil: [ '''' ] ifNotNil: [ input text asString ].
 activityLimit := bodyPane ifNotNil: [
  bodyPane userData at: #activityHistoryLimit ifAbsent: [ nil ] ].
 space ifNil: [ space := BlSpace new ].
 space title: ''织境对话''.
 space root removeChildren.
 root := BrVerticalPane new matchParent; background: Color white; yourself.
 root layout cellSpacing: 0.
 body := BlElement new layout: BlFrameLayout new; constraintsDo: [ :c | c horizontal matchParent. c vertical matchParent ]; yourself.
 activityLimit ifNotNil: [ body userData at: #activityHistoryLimit put: activityLimit ].
 bodyPane := body.
 left := BrVerticalPane new matchParent; yourself.
 conversationPane := left.
 sessionLabel := nil.
 followOutput ifNil: [ followOutput := true ].
 historyItems := OrderedCollection new.
 history := BrSimpleList new matchParent;
  itemType: [ :factory :item :index | LMConversationMessageView ];
  itemStencil: [ LMConversationMessageView new controller: self; yourself ];
  itemDataBinder: [ :row :item :index | self bindMessageRow: row item: item ];
  items: historyItems; yourself.
 historyFrame := BlElement new layout: BlFrameLayout new; constraintsDo: [ :c | c horizontal matchParent. c vertical matchParent ]; yourself.
 historyFrame addChild: history.
 followButton := LMChatStyle jumpButton: [
  followOutput := true. history userData at: #newContent put: false.
  self followLatest. self updateFollowButton ].
 followButton margin: (BlInsets bottom: 3).
 followButton constraintsDo: [ :c | c frame horizontal alignCenter. c frame vertical alignBottom ].
 historyFrame addChild: followButton.
 (history childNamed: #scrollable) addEventHandlerOn: BlElementScrolledEvent do: [ :event |
  event target == event currentTarget eventDispatcher ifTrue: [ self updateFollowAfterScroll: event delta ] ].
 self updateFollowButton.
 left addChild: historyFrame.
 composer := BrVerticalPane new hMatchParent; vFitContent;
  margin: (BlInsets top: 6 right: 26 bottom: 11 left: 26);
  border: (BlBorder paint: (Color gray: 0.85) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 7); yourself.
 composerPane := composer.
 inputInset := 13.
 input := self editor beEditable; vExact: self composerMinimumHeight; text: draft;
  padding: (BlInsets top: 11 right: inputInset bottom: 5 left: inputInset); yourself.
 self configureInputShortcuts.
 input editor addEventHandlerOn: BrTextEditorModifiedEvent do: [ :event | self resizeComposer ].
 composer addChild: input.
 placeholderLabel := self label: ''描述你想做的事…'' size: 14.
 placeholderLabel aptitude foreground: (Color gray: 0.6).
 placeholderLabel constraintsDo: [ :c | c ignoreByLayout ].
 placeholderLabel position: inputInset@11.
 placeholderLabel addEventHandlerOn: BlClickEvent do: [ :event | input requestFocus. event consumed: true ].
 composer addChild: placeholderLabel.
 footer := BrHorizontalPane new hMatchParent; vExact: 35; alignCenterLeft;
  padding: (BlInsets top: 0 right: 8 bottom: 7 left: inputInset); yourself.
 footer layout cellSpacing: 0.
 status := (self label: ''Enter 发送 · Shift Enter 换行'' size: 12) hMatchParent; yourself.
 footer addChild: status.
 stopButton := LMChatStyle button: ''停止'' action: [ self cancelCurrentTurn ] foreground: (Color gray: 0.22) background: (Color gray: 0.97).
 stopButton margin: (BlInsets left: 5).
 stopButton border: (BlBorder paint: (Color gray: 0.84) width: 1); geometry: (BlRoundedRectangleGeometry cornerRadius: 4).
 stopButton visibility: BlVisibility gone.
 footer addChild: stopButton.
 voiceComposer := LMVoiceComposer new.
 footer addChild: (voiceComposer buildFor: self).
 footer addChild: ((LMChatStyle button: ''发送'' action: [ self sendMessage ]
  foreground: Color white background: (Color gray: 0.2)) hExact: 50; vExact: 28; margin: (BlInsets left: 5); yourself).
 composer addChild: footer. left addChild: composer.
 left addEventHandlerOn: BlElementExtentChangedEvent do: [ :event | self layoutComposerForWidth: left width ].
 activityFollow := true.
 activityPane := self buildActivityPane.
 splitter := BlElement new layout: BlFrameLayout new; mouseCursor: BlResizeColumnCursor new;
  constraintsDo: [ :c | c horizontal exact: 12. c vertical matchParent. c frame horizontal alignRight ]; yourself.
 divider := BlElement new background: (Color gray: 0.91);
  constraintsDo: [ :c | c horizontal exact: 1. c vertical matchParent. c frame horizontal alignCenter ]; yourself.
 splitter addChild: divider.
 splitterElement := splitter.
 splitter addEventHandlerOn: BlMouseEnterEvent do: [ :event | divider background: (Color gray: 0.66) ].
 splitter addEventHandlerOn: BlMouseLeaveEvent do: [ :event | divider background: (Color gray: 0.91) ].
 splitter addEventHandlerOn: BlDragStartEvent do: [ :event |
  splitter userData at: #resizeAnchor put: { event position x. activityPane width }.
  event consumed: true ].
 splitter addEventHandlerOn: BlDragEvent do: [ :event |
  (splitter userData at: #resizeAnchor ifAbsent: [ nil ]) ifNotNil: [ :start |
   self resizeActivityTo: start second + start first - event position x ].
  event consumed: true ].
 splitter addEventHandlerOn: BlDragEndEvent do: [ :event |
  splitter userData removeKey: #resizeAnchor ifAbsent: [ nil ].
  event consumed: true ].
 body addEventHandlerOn: BlElementExtentChangedEvent do: [ :event |
  self updateResponsiveGeometry. self defer: [ body requestLayout ] ].
 body addChildren: { left. activityPane. splitter }. root addChild: body.
 self updateResponsiveGeometry.
 space root addChild: root.
 lastText := ''''. lastActivity := ''''. lastPayload := nil. layoutVersion := 7. pendingAnchor := anchor.
 self layoutComposerForWidth: left width.
 self refresh.
 ^ self'.
ui compile: 'buildActivityPane
 | pane viewport empty |
 pane := BrVerticalPane new layout: BlFrameLayout new; vMatchParent;
  hExact: (activityWidth ifNil: [ self defaultActivityWidthFor: root width ]);
  background: (Color gray: 0.977);
  constraintsDo: [ :c | c frame horizontal alignRight ]; yourself.
 activityItems := OrderedCollection new.
 activity := BrSimpleList new matchParent;
  itemType: [ :factory :item :index | LMConversationActivityView ];
  itemStencil: [ LMConversationActivityView new controller: self; yourself ];
  itemDataBinder: [ :row :item :index | self bindActivityRow: row item: item ];
  items: activityItems; margin: (BlInsets top: 34); yourself.
 viewport := activity childNamed: #scrollable.
 viewport addEventHandlerOn: BlElementScrolledEvent do: [ :event |
  (event target == viewport eventDispatcher and: [ event delta y isZero not ]) ifTrue: [
   activityFollow := viewport canScrollDown not.
   (event delta y < 0 and: [ viewport canScrollUp not ]) ifTrue: [ self requestOlderActivities ] ] ].
 viewport addEventHandlerOn: BlMouseWheelEvent do: [ :event |
  (event isScrollUp and: [ viewport canScrollUp not ]) ifTrue: [ self requestOlderActivities ] ].
 empty := self label: '''' size: 13.
 empty aptitude foreground: (Color gray: 0.48).
 empty margin: (BlInsets top: 49).
 empty constraintsDo: [ :c | c frame horizontal alignCenter ].
 activity userData at: #emptyLabel put: empty.
 pane addChildren: { activity. empty. self activityToolbar }.
 ^ pane'.
ui compile: 'activityToolbar
 | bar notice rotate settings |
 bar := BrHorizontalPane new id: #loomActivityToolbar; hMatchParent; vExact: 33; alignCenterLeft;
  padding: (BlInsets left: 12 right: 12);
  border: (BlBorder paint: (Color gray: 0.90) width: 1);
  constraintsDo: [ :c | c frame vertical alignTop ]; yourself.
 bar layout cellSpacing: 4.
 notice := (self label: '''' size: 12) hMatchParent; yourself.
 notice aptitude foreground: (Color gray: 0.44).
 rotate := LMChatStyle replyAction: #newCodexSession icon: ''repeat-2'' action: [
  self runCodexSetting: [ LoomCodex newConversation ] notice: notice completed: '''' transient: true ].
 rotate addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [ self label: ''切换到新 Codex 会话'' size: 12 ]).
 settings := LMChatStyle replyAction: #loomCodexSettings icon: ''settings'' action: [ self showCodexSettings ].
 bar addChildren: { notice. rotate. settings }.
 ^ bar'.
ui compile: 'button: title action: block ^ LMChatStyle button: title action: block'.
ui compile: 'cancelCurrentTurn
 | id file temporary |
 id := (LoomConversation instVarNamed: ''client'') activeRequestId.
 id ifNil: [ ^ self ].
 file := BridgeIPC / ''codex-cancel'' / (id , ''.json'').
 file exists ifFalse: [
  temporary := file parent / (id, ''.tmp'').
  temporary binaryWriteStreamDo: [ :out | out nextPutAll: ''{}'' utf8Encoded; truncate: 2 ].
  temporary renameTo: file basename ].
 status text: ''正在停止…'''.
ui compile: 'closed
 voiceComposer ifNotNil: [ voiceComposer close ].
 self stopRefreshing'.
ui compile: 'collectUpdate
 | directory key current records invocation messages statusText reply page limit partial audioIndex jobs activeClient |
 directory := LoomConversation directory.
 key := { (directory / ''inputs'') modificationTime. (directory / ''replies'') modificationTime }.
 (recordCache isNil or: [ recordKey ~= key ]) ifTrue: [
  recordCache := LoomConversation records asArray. recordKey := key ].
 records := recordCache.
 current := LoomConversation instVarNamed: ''currentId''.
 activeClient := LoomConversation instVarNamed: ''client''.
 invocation := current ifNotNil: [ activeClient activeRequestId ].
 limit := bodyPane userData at: #activityHistoryLimit ifAbsent: [ self activityPageSize ].
 page := (bodyPane userData at: #activityTimeline ifAbsentPut: [ LMActivityReader new ])
  pageOf: limit focus: invocation session: LoomSessions mainId.
 partial := (page notNil and: [ invocation notNil and: [
  (page at: ''focus'') = invocation and: [ activeClient activeRequestId = invocation ] ] ])
  ifTrue: [ page at: ''answer'' ] ifFalse: [ '''' ].
 messages := OrderedCollection new.
 records do: [ :record | | response content entry id audioId showReply audio |
  id := record at: ''id''.
  response := record at: ''reply'' ifAbsent: [ nil ].
  audioId := record at: ''audioId'' ifAbsent: [ nil ].
  entry := Dictionary new at: ''id'' put: id, ''-user'';
   at: ''role'' put: ''user''; at: ''text'' put: (record at: ''text'');
   at: ''createdAt'' put: (record at: ''createdAt'' ifAbsent: [ '''' ]); yourself.
  showReply := response notNil or: [ audioId isNil or: [ current = id ] ].
  audioId ifNotNil: [
   jobs ifNil: [ audioIndex := LMVoice index. jobs := LMVoice jobsById: audioIndex ].
   self addRecording: (jobs at: audioId ifAbsent: [ nil ]) id: audioId
    playing: (audioIndex at: ''playingId'' ifAbsent: [ nil ]) = audioId
    correction: (LoomConversation speechCorrectionAt: id) awaitingReply: response isNil to: entry.
   audio := entry at: ''audio''.
   (#(correcting correctionFailed) includes: (audio at: ''stage'')) ifTrue: [ showReply := false ] ].
  messages add: entry.
  showReply ifTrue: [
   content := response ifNil: [ current = id ifTrue: [ partial ] ifFalse: [ '''' ] ]
    ifNotNil: [ response at: ''text'' ].
   messages add: (Dictionary new at: ''id'' put: id, ''-assistant'';
    at: ''role'' put: ''assistant''; at: ''text'' put: content;
    at: ''pending'' put: response isNil;
    at: ''ok'' put: (response ifNil: [ true ] ifNotNil: [ response at: ''ok'' ]); yourself) ] ].
 statusText := current ifNil: [ ''已完成'' ] ifNotNil: [
  invocation ifNil: [ ''正在准备'' ] ifNotNil: [ ''正在处理'' ] ].
 records ifEmpty: [ statusText := ''等待消息'' ].
 current ifNil: [
  records ifNotEmpty: [ reply := records last at: ''reply'' ifAbsent: [ nil ].
   (reply notNil and: [ (reply at: ''ok'') not ]) ifTrue: [ statusText := ''本轮未完成'' ] ] ].
 ^ Dictionary new at: ''messages'' put: messages asArray;
  at: ''activities'' put: (page ifNil: [ #() ] ifNotNil: [ page at: ''items'' ]);
  at: ''activityLimit'' put: (page ifNil: [ 0 ] ifNotNil: [ page at: ''limit'' ]);
  at: ''hasOlderActivities'' put: (page notNil and: [ page at: ''older'' ]);
  at: ''status'' put: statusText; at: ''processing'' put: current notNil; yourself'.
ui compile: 'addRecording: job id: id playing: playing correction: correction awaitingReply: awaitingReply to: entry
 | transcript caption original stage state |
 transcript := LMVoice transcribedText: job.
 state := LMVoice transcriptionStatus: job.
 stage := #transcription.
 correction ifNotNil: [
  (correction at: ''ok'') ifTrue: [ transcript := correction at: ''text''. stage := #corrected. state := '''' ]
   ifFalse: [ stage := #correctionFailed. state := ''纠正失败'' ]
 ] ifNil: [
  (awaitingReply and: [ transcript isNotEmpty ]) ifTrue: [
   stage := #correcting. state := ''正在纠正…''. transcript := '''' ] ].
 caption := entry at: ''text''.
 transcript ifNotEmpty: [ entry at: ''text'' put: (caption
  ifEmpty: [ transcript ] ifNotEmpty: [ caption, String cr, transcript ]) ].
 original := job ifNotNil: [ job at: ''original'' ifAbsent: [ nil ] ].
 entry at: ''audio'' put: (Dictionary new
  at: ''id'' put: id;
  at: ''duration'' put: (job ifNil: [ 0 ] ifNotNil: [ job at: ''duration'' ifAbsent: [ 0 ] ]);
  at: ''playing'' put: playing;
  at: ''playable'' put: (original notNil and: [ (LMVoice directory / id / original) exists ]);
  at: ''status'' put: state; at: ''stage'' put: stage; yourself)'.
ui compile: 'configureInputShortcuts
 input addEditorShortcut: (BrEditorShortcut new
  name: ''Send Loom message'';
  combination: BlKeyCombination return;
  repeatable: false;
  performBlock: [ self sendMessage ];
  yourself).
 input addEditorShortcut: (BrEditorShortcut new
  name: ''Insert Loom message newline'';
  combination: (BlKeyCombination shiftReturn or: (BlKeyCombination builder shift numpadEnter build));
  performBlock: [ :editor | editor insertLineEndingAtCursor ];
  yourself).
 ^ self'.
ui compile: 'configureTab: model in: world
 | worldElement |
 worldElement := world instVarNamed: ''worldElement''.
 model widgetDo: [ :widget |
  widget icon: BrGlamorousVectorIcons emphasizedChat; label: ''''.
  (widget childNamed: #label) visibility: BlVisibility gone ].
 model actionbarStencil: [ :tabModel | BrToolbar new
  aptitude: (BrGlamorousToolbarAptitude new spacing: 0);
  margin: (BlInsets left: 6);
  addItems: { worldElement closeButtonFor: tabModel };
  yourself ]'.
ui compile: 'copyLastReply
 historyItems ifNotEmpty: [
  GtClipboard clipboardText: ((historyItems reversed detect: [ :entry | (entry at: ''role'') = ''assistant'' ]) at: ''text'') ]'.
ui compile: 'defaultActivityWidthFor: width
 width >= 1600 ifTrue: [ ^ 400 ].
 (width > 0 and: [ width <= 1100 ]) ifTrue: [ ^ 340 ].
 ^ 368'.
ui compile: 'defer: block
 self hostWorld ifNotNil: [ :world | world enqueueTask: (BlTaskAction new action: block; yourself) ]'.
ui compile: 'editor ^ LMChatStyle editor: 14'.
ui compile: 'followActivities
 (activityFollow and: [ activityItems notEmpty ]) ifTrue: [
  activity scrollToIndex: activityItems size ]'.
ui compile: 'followLatest
 (history notNil and: [ historyItems notNil and: [ historyItems notEmpty ] ])
  ifTrue: [
   history scrollToIndex: historyItems size.
   self defer: [ | viewport last |
    viewport := history childNamed: #scrollable.
    last := viewport layout childAtPosition: historyItems size.
    (followOutput and: [ last notNil ]) ifTrue: [
     viewport scrollBy: 0 @ ((last boundsInParent bottom - viewport height) max: 0) ] ] ]'.
ui compile: 'historyAnchor ^ self listAnchor: history with: historyItems'.
ui compile: 'listAnchor: widget with: items
 | list child holder index |
 (items isNil or: [ (widget isKindOf: BrSimpleList) not ]) ifTrue: [ ^ nil ].
 list := widget childNamed: #scrollable.
 child := list layout findFirstVisibleChildClosestToStartCompletelyVisible: false acceptPartiallyVisible: true.
 child ifNil: [ ^ nil ].
 holder := list elementHolderOf: child.
 index := holder layoutPosition.
 (index between: 1 and: items size) ifFalse: [ ^ nil ].
 ^ { (items at: index) at: ''id''. child boundsInParent top }'.
ui compile: 'requestOlderActivities
 | requested |
 (lastPayload notNil and: [ lastPayload at: ''hasOlderActivities'' ifAbsent: [ false ] ]) ifFalse: [ ^ self ].
 requested := bodyPane userData at: #activityHistoryLimit ifAbsent: [ self activityPageSize ].
 (lastPayload at: ''activityLimit'') = requested ifTrue: [
  activityFollow := false.
  bodyPane userData at: #activityHistoryLimit put: requested + self activityPageSize ]'.
ui compile: 'activityPageSize ^ 100'.
ui compile: 'restoreActivityAnchor: anchor
 | list viewport |
 list := activity.
 viewport := list childNamed: #scrollable.
 viewport enqueueTask: (BlDelayedTaskAction new delay: 40 milliSeconds; action: [ | index |
  (activity == list and: [ activityFollow not ]) ifTrue: [
   index := activityItems findFirst: [ :entry | (entry at: ''id'') = anchor first ].
   index > 0 ifTrue: [ list scrollToIndex: index offset: anchor second ] ] ]; yourself)'.
ui compile: 'hostWorld
 ^ GtWorld allOpenWorlds
  detect: [ :world | (world host isKindOf: BlWinitHost)
   and: [ world tabGroup tabs anySatisfy: [ :tab | tab model == space ] ] ]
  ifNone: [ nil ]'.
ui compile: 'isOpen ^ self hostWorld notNil'.
ui compile: 'label: text size: size ^ LMChatStyle label: text size: size'.
ui compile: 'layoutComposerForWidth: width
 | inset margin |
 composerPane ifNil: [ ^ self ].
 inset := LMChatStyle readingInsetFor: width viewport: (self viewportWidth ifNil: [ width ]) padding: 18 medium: 16 narrow: 12.
 margin := BlInsets top: 6 right: inset bottom: 11 left: inset.
 composerPane margin = margin ifFalse: [ composerPane margin: margin ].
 self resizeComposer'.
ui compile: 'messageSource: value for: id
 messageSourceStates ifNil: [ messageSourceStates := Dictionary new ].
 messageSourceStates at: id put: value'.
ui compile: 'messageSourceFor: id
 messageSourceStates ifNil: [ messageSourceStates := Dictionary new ].
 ^ messageSourceStates at: id ifAbsent: [ false ]'.
ui compile: 'presentationSpace ^ space'.
ui compile: 'refresh
 status ifNotNil: [
  errorText ifNotNil: [ status text: errorText ] ]'.
ui compile: 'resizeComposer
 | text lines count usable ideal |
 input ifNil: [ ^ self ].
 text := input text asString.
 placeholderLabel ifNotNil: [ placeholderLabel visibility: (
  text isEmpty ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ]) ].
 usable := (input width - 26) max: 200.
 lines := text lines.
 count := lines size max: 1.
 lines do: [ :line | | width |
  width := line inject: 0 into: [ :sum :char | sum + (char asInteger > 127 ifTrue: [ 14 ] ifFalse: [ 7 ]) ].
  count := count + (width // usable) ].
 (text notEmpty and: [ #(10 13) includes: text last asInteger ]) ifTrue: [ count := count + 1 ].
 ideal := ((count * 24 + 16) min: 150) max: self composerMinimumHeight.
 input constraints vertical resizer size = ideal ifFalse: [ input vExact: ideal ]'.
ui compile: 'composerMinimumHeight ^ 62'.
ui compile: 'restore
 self shouldRestore ifFalse: [ layoutVersion := nil. ^ self ].
 self stopRefreshing.
 recordCache := nil. recordKey := nil.
 self isOpen ifFalse: [ layoutVersion := nil. ^ self show ].
 "Native rendering handles and event callbacks must be recreated after image restore."
 self build.
 self startRefreshing.
 self defer: [ self tab ifNotNil: [ :model | self configureTab: model in: self hostWorld ] ].
 ^ self'.
ui compile: 'saveRuntime
 errorText := ''正在保存…''. self refresh.
 [ [ LMExecution checkpoint.
   self defer: [ errorText := ''已保存''. self refresh ]
  ] on: Error do: [ :error | self defer: [ errorText := error messageText. self refresh ] ]
 ] fork'.
ui compile: 'showCodexSettings
 | file options overlay panel close |
 (activityPane userData includesKey: #codexSettings) ifTrue: [ ^ self ].
 file := BridgeIPC / ''codex-options.json''.
 file exists ifFalse: [
  status text: ''Codex 配置正在加载…''. ^ self ].
 options := STONJSON fromString: file contents.
 overlay := BlElement new id: #loomCodexSettingsOverlay; layout: BlFrameLayout new;
  background: (Color black alpha: 0.18);
  constraintsDo: [ :c | c horizontal matchParent. c vertical matchParent ]; yourself.
 panel := BrVerticalPane new hExact: ((366 min: activityPane width - 20) max: 260); vFitContent;
  padding: (BlInsets all: 16); background: Color white;
  border: (BlBorder paint: (Color gray: 0.88) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 8);
  constraintsDo: [ :c | c frame horizontal alignCenter. c frame vertical alignCenter ]; yourself.
 panel layout cellSpacing: 9.
 overlay addEventHandlerOn: BlElementExtentChangedEvent do: [ :event |
  panel hExact: ((366 min: overlay width - 20) max: 0) ].
 close := [ overlay removeFromParent. activityPane userData removeKey: #codexSettings ifAbsent: [ ] ].
 overlay addEventHandlerOn: BlClickEvent do: [ :event | event target == overlay ifTrue: [ close value ] ].
 overlay addShortcut: (BlShortcutWithAction new combination: BlKeyCombination escape;
  action: [ close value ]; yourself).
 self renderCodexSettings: options in: panel close: close.
 overlay addChild: panel. activityPane addChild: overlay.
 activityPane userData at: #codexSettings put: overlay'.
ui compile: 'renderCodexSettings: options in: panel close: close
 | values models model heading modelField effortField fastSwitch notice footer save redraw openField toggle modelLabel effortLabel |
 panel removeChildren.
 panel userData at: #configurationDraft put: options.
 values := options at: ''current''.
 models := options at: ''models''.
 model := models detect: [ :entry | (entry at: ''id'') = (values at: ''model'') ].
 redraw := [ self renderCodexSettings: options in: panel close: close ].
 openField := panel userData at: #openSettingsMenu ifAbsent: [ nil ].
 toggle := [ :field |
  panel userData at: #openSettingsMenu put: (openField = field ifTrue: [ nil ] ifFalse: [ field ]).
  redraw value ].
 heading := BrHorizontalPane new hMatchParent; vFitContent; alignCenterLeft; yourself.
 heading addChild: ((self label: (''设置'' asRopedText bold; yourself) size: 15) hMatchParent; yourself).
 heading addChild: (LMChatStyle replyAction: #closeSettings icon: ''x'' action: close).
 panel addChild: heading.
 modelLabel := [ :entry | entry at: ''label'' ].
 modelField := self settingsTrigger: (modelLabel value: model) expanded: openField = #model
  action: [ toggle value: #model ].
 modelField id: #codexModelOptions.
 panel addChild: (self settingsRow: ''模型'' control: modelField).
 openField = #model ifTrue: [
  panel addChild: (self settingsMenu: models selected: model label: modelLabel change: [ :entry |
   values at: ''model'' put: (entry at: ''id'').
   ((entry at: ''efforts'') includes: (values at: ''effort'')) ifFalse: [
    values at: ''effort'' put: (entry at: ''defaultEffort'') ].
   (entry at: ''fast'') ifFalse: [ values at: ''fast'' put: false ]. toggle value: #model ]) ].
 effortLabel := [ :effort | effort capitalized ].
 effortField := self settingsTrigger: (effortLabel value: (values at: ''effort'')) expanded: openField = #effort
  action: [ toggle value: #effort ].
 effortField id: #codexEffortOptions.
 panel addChild: (self settingsRow: ''思考强度'' control: effortField).
 openField = #effort ifTrue: [
  panel addChild: (self settingsMenu: (model at: ''efforts'') selected: (values at: ''effort'')
   label: effortLabel change: [ :effort | values at: ''effort'' put: effort. toggle value: #effort ]) ].
 fastSwitch := self settingsSwitch: (values at: ''fast'') action: [
  (activityPane userData at: #codexSettingPending ifAbsent: [ false ]) ifFalse: [
   values at: ''fast'' put: (values at: ''fast'') not. redraw value ] ].
 fastSwitch id: #codexFast; enabled: (model at: ''fast'').
 panel addChild: (self settingsRow: ''Fast'' control: fastSwitch).
 notice := self label: ''设置在下一次调用时生效。'' size: 12.
 panel addChild: notice.
 footer := BrHorizontalPane new hMatchParent; vFitContent; alignCenterLeft; yourself.
 footer layout cellSpacing: 8.
 footer addChild: (BrHorizontalPane new hMatchParent; vExact: 1; yourself).
 save := LMChatStyle button: ''保存设置'' action: [
  self runCodexSetting: [ LoomCodex configure: values copy ] notice: notice completed: ''设置已保存。'' transient: false ].
 save id: #codexSave.
 footer addChild: save. panel addChild: footer'.
ui compile: 'settingsRow: caption control: control
 | row |
 row := BrHorizontalPane new hMatchParent; vExact: 32; alignCenterLeft; yourself.
 row addChildren: { (self label: caption size: 13) hExact: 84; yourself. control }.
 ^ row'.
ui compile: 'settingsTrigger: caption expanded: expanded action: action
 | button label |
 label := (self label: caption size: 13) hMatchParent; yourself.
 button := BrButton new aptitude: BrGlamorousButtonLayoutAptitude new;
  hMatchParent; vExact: 30; alignCenterLeft; beFocusable;
  padding: (BlInsets left: 9 right: 8);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 5);
  border: (BlBorder paint: (Color gray: 0.86) width: 1); action: action; yourself.
 button addAptitude: (BrStyleCommonAptitude new
  default: [ :style | style background: Color white ];
  hovered: [ :style | style background: (Color gray: 0.96) ]).
 button addChildren: { label. LMIcons iconNamed: (expanded ifTrue: [ ''chevron-up'' ] ifFalse: [ ''chevron-down'' ]) size: 14 color: (Color gray: 0.48) }.
 ^ button'.
ui compile: 'settingsMenu: values selected: selected label: label change: change
 | menu viewport row maximum |
 menu := BrVerticalPane new hMatchParent; vFitContent; padding: (BlInsets all: 4); yourself.
 values do: [ :value | | option |
  option := LMChatStyle button: (label value: value) action: [
   (activityPane userData at: #codexSettingPending ifAbsent: [ false ]) ifFalse: [ change value: value ] ]
   foreground: (Color gray: 0.2) background: (value = selected ifTrue: [ Color gray: 0.92 ] ifFalse: [ Color white ]).
  option hMatchParent; alignCenterLeft; geometry: (BlRoundedRectangleGeometry cornerRadius: 4).
  menu addChild: option ].
 maximum := activityPane height > 0 ifTrue: [ (activityPane height - 290) max: 64 ] ifFalse: [ 184 ].
 viewport := BrScrollPane new id: #loomSettingsMenu;
  aptitude: BrScrollPaneAptitude new + BrGlamorousWithVerticalScrollbarAptitude new;
  hMatchParent; vExact: ((values size * 26 + 8) min: (184 min: maximum));
  geometry: (BlRoundedRectangleGeometry cornerRadius: 5);
  border: (BlBorder paint: (Color gray: 0.86) width: 1); content: menu; yourself.
 row := BrHorizontalPane new hMatchParent; vFitContent; yourself.
 row addChildren: { BrHorizontalPane new hExact: 84; vExact: 1; yourself. viewport }.
 ^ row'.
ui compile: 'settingsSwitch: isOn action: action
 | track knob |
 track := BrButton new layout: BlFrameLayout new; hExact: 34; vExact: 20; beFocusable;
  padding: (BlInsets left: 3 right: 3);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 10);
  background: (isOn ifTrue: [ Color gray: 0.23 ] ifFalse: [ Color gray: 0.8 ]);
  action: action; yourself.
 knob := BlElement new size: 14 @ 14; background: Color white;
  geometry: (BlRoundedRectangleGeometry cornerRadius: 7);
  constraintsDo: [ :c | c frame vertical alignCenter. isOn ifTrue: [ c frame horizontal alignRight ] ifFalse: [ c frame horizontal alignLeft ] ]; yourself.
 track addChild: knob.
 ^ track'.
ui compile: 'runCodexSetting: operation notice: notice completed: message transient: transient
 | data |
 data := activityPane userData.
 (data at: #codexSettingPending ifAbsent: [ false ]) ifTrue: [ ^ self ].
 data at: #codexSettingPending put: true.
 notice text: ''等待执行…''.
 [ | statusText |
  statusText := [ operation value. message ] on: Error do: [ :error | error messageText ].
  self defer: [
   data removeKey: #codexSettingPending ifAbsent: [ ]. notice text: statusText.
   (transient and: [ statusText notEmpty ]) ifTrue: [ notice enqueueTask: (BlDelayedTaskAction new delay: 3500 milliSeconds;
    action: [ notice text asString = statusText ifTrue: [ notice text: '''' ] ]; yourself) ] ]
 ] fork'.
ui compile: 'sendMessage
 | text |
 text := input text asString.
 text trimBoth ifEmpty: [ ^ self ].
 [ LoomConversation submit: text. input text: ''''. errorText := nil ]
  on: Error do: [ :error | errorText := error messageText ].
 self refresh.
 self resizeComposer'.
ui compile: 'voiceNotice: text
 errorText := text.
 self refresh'.
ui compile: 'toggleRecordingPlayback: audioId
 voicePlaybackPending = true ifTrue: [ ^ self ].
 voicePlaybackPending := true.
 [ [ [ | playing action receipt |
    playing := (LMVoice index at: ''playingId'' ifAbsent: [ nil ]) = audioId.
    action := playing ifTrue: [ ''stop-playback'' ] ifFalse: [ ''play'' ].
    receipt := LMVoice await: (LMVoice request: action options: (Dictionary new at: ''audioId'' put: audioId; yourself)).
    (receipt at: ''ok'') ifFalse: [ self error: (receipt at: ''error'') ].
    self defer: [ self voiceNotice: nil ]
   ] on: Error do: [ :error | | notice |
    notice := error messageText. self defer: [ self voiceNotice: notice ] ]
 ] ensure: [ voicePlaybackPending := false ] ] fork'.
ui compile: 'shouldRestore
 ^ self isOpen or: [ layoutVersion ~= 7 and: [ space notNil and: [ space isOpened ] ] ]'.
ui compile: 'show
 | world model |
 self stopRefreshing.
 (space notNil and: [ space isOpened ]) ifTrue: [
  (BlParallelUniverse forHost: space host class) closeSpaceSynchronously: space ].
 (layoutVersion ~= 7 or: [ voiceComposer isNil or: [ voiceComposer isClosed ] ]) ifTrue: [ self build ].
 world := self hostWorld ifNil: [
  GtWorld allOpenWorlds detect: [ :each | each host isKindOf: BlWinitHost ]
   ifNone: [ self error: ''请先打开 GT 主界面'' ] ].
 self hostWorld ifNil: [ world showSpace: space ].
 model := self tab.
 model select.
 world requestNextPulse; toFront.
 self startRefreshing.
 self defer: [
  self configureTab: model in: world.
  followOutput ifTrue: [ self followLatest ] ].
 ^ self'.
ui compile: 'space ^ self hostWorld ifNil: [ space ]'.
ui compile: 'startRefreshing
 | generation |
 self stopRefreshing.
 generation := refreshGeneration.
 refreshQueued := false.
 poller := [
  [ self isOpen ] whileTrue: [
   refreshQueued ifFalse: [
    [ | payload |
     payload := self collectUpdate.
     refreshQueued := true.
     self defer: [
      refreshGeneration = generation ifTrue: [
       [ self applyUpdate: payload ] ensure: [ refreshQueued := false ] ] ]
    ] on: Error do: [ :error |
     self defer: [ status text: ''活动读取失败：'', error messageText ].
     refreshQueued := false ] ].
   (Delay forMilliseconds: 150) wait ]
 ] fork.
 poller name: ''Loom conversation event reader'''.
ui compile: 'stopRefreshing
 refreshGeneration := (refreshGeneration ifNil: [ 0 ]) + 1.
 poller ifNotNil: [ poller terminate. poller := nil ]'.
ui compile: 'syncList: list collection: collection with: values
 | oldCount common sameIdentity source changed |
 oldCount := collection size. common := oldCount min: values size.
 sameIdentity := (1 to: common) allSatisfy: [ :index |
  ((collection at: index) at: ''id'') = ((values at: index) at: ''id'') ].
 sameIdentity ifFalse: [
  collection removeAll; addAll: values.
  list items: collection. ^ true ].
 source := (list childNamed: #scrollable) dataSource.
 changed := false.
 1 to: common do: [ :index |
  (collection at: index) = (values at: index) ifFalse: [
   collection at: index put: (values at: index).
   source notifyItemsChanged: (index to: index). changed := true ] ].
 values size > oldCount ifTrue: [
  oldCount + 1 to: values size do: [ :index | collection add: (values at: index) ].
  source notifyItemsInserted: (oldCount + 1 to: values size). changed := true ].
 values size < oldCount ifTrue: [
  [ collection size > values size ] whileTrue: [ collection removeLast ].
  source notifyItemsRemoved: (values size + 1 to: oldCount). changed := true ].
 ^ changed'.
ui compile: 'tab
 | world |
 world := self hostWorld.
 ^ world ifNotNil: [ world tabGroup tabs detect: [ :each | each model == space ] ifNone: [ nil ] ]'.
ui compile: 'toggleActivityPane
 activityHidden := activityPane visibility class = BlVisibility visible class.
 self updateResponsiveGeometry'.
ui compile: 'transcriptFor: records
 ^ String streamContents: [ :out |
  records do: [ :message | | reply partial |
   out nextPutAll: ''你''; cr; nextPutAll: (message at: ''text''); cr; cr.
   (message at: ''audioId'' ifAbsent: [ nil ]) ifNotNil: [ :audioId |
    | job |
    job := LMVoice job: audioId.
    out nextPutAll: ''[音频消息]''; cr.
    job ifNotNil: [ out nextPutAll: (LMVoice label: job); cr;
     nextPutAll: (job at: ''transcript'' ifAbsent: [ job at: ''error'' ifAbsent: [ '''' ] ]); cr ].
    out cr ].
   reply := message at: ''reply'' ifAbsent: [ nil ].
   reply
    ifNotNil: [
     out nextPutAll: ((reply at: ''ok'') ifTrue: [ ''Loom'' ] ifFalse: [ ''错误'' ]);
      cr; nextPutAll: (reply at: ''text''); cr; cr ]
    ifNil: [
     partial := lastPayload ifNil: [ '''' ] ifNotNil: [
      ((lastPayload at: ''messages'') detect: [ :entry | (entry at: ''id'') = ((message at: ''id''), ''-assistant'') ]
       ifNone: [ Dictionary new ]) at: ''text'' ifAbsent: [ '''' ] ].
     out nextPutAll: ''Loom''; cr; nextPutAll: partial.
     "Keep the in-flight answer append-only." ] ] ]'.
ui compile: 'updateEditor: editor previous: previous text: text
 | firstIndex |
 text = previous ifTrue: [ ^ previous ].
 followOutput ifFalse: [
  editor firstVisibleSegment ifNotNil: [ :segment | firstIndex := segment index ] ].
 (previous notNil and: [ previous notEmpty and: [ text beginsWith: previous ] ])
  ifTrue: [
   editor editor inserter withoutSelectionDelete; withoutCursorUpdate; withoutSelectionUpdate;
    atEnd; string: (text allButFirst: previous size); insert ]
  ifFalse: [ editor text: text ].
 followOutput
  ifTrue: [ editor scrollToLast ]
  ifFalse: [ firstIndex ifNotNil: [
   editor scrollToPosition: ((firstIndex min: editor editor text lineCount) max: 1) ] ].
 ^ text'.
ui compile: 'updateActivityEmpty
 | empty message |
 empty := activity userData at: #emptyLabel.
 message := (lastPayload at: ''processing'') ifTrue: [ ''等待活动…'' ] ifFalse: [ ''暂无活动'' ].
 empty text asString = message ifFalse: [ empty text: message ].
 empty visibility: (activityItems isEmpty ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ])'.
ui compile: 'updateFollowAfterScroll: delta
 | viewport |
 delta y isZero ifTrue: [ ^ self ].
 viewport := history childNamed: #scrollable.
 followOutput := viewport canScrollDown not.
 followOutput ifTrue: [ history userData at: #newContent put: false ].
 self updateFollowButton'.
ui compile: 'updateFollowButton
 | newContent |
 followButton ifNil: [ ^ self ].
 newContent := history userData at: #newContent ifAbsent: [ false ].
 followButton visibility: ((followOutput not and: [ newContent ]) ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ])'.
ui compile: 'maximumActivityWidthFor: width
 ^ width > 800 ifTrue: [ 820 min: width - 360 ] ifFalse: [ 820 ]'.
ui compile: 'resizeActivityTo: width
 bodyPane width <= 800 ifTrue: [ ^ self ].
 activityWidth := (width max: 290) min: (self maximumActivityWidthFor: bodyPane width).
 self updateResponsiveGeometry'.
ui compile: 'updateResponsiveGeometry
 | width narrow visible desired inset margin |
 (bodyPane isNil or: [ activityPane isNil or: [ splitterElement isNil ] ]) ifTrue: [ ^ self ].
 width := bodyPane width.
 narrow := width > 0 and: [ width <= 800 ].
 visible := activityHidden ifNil: [ narrow not ] ifNotNil: [ activityHidden not ].
 desired := narrow
  ifTrue: [ 380 min: width * 0.91 ]
  ifFalse: [ (activityWidth ifNil: [ self defaultActivityWidthFor: width ]) min: (self maximumActivityWidthFor: width) ].
 inset := (visible and: [ narrow not ]) ifTrue: [ desired + 4 ] ifFalse: [ 0 ].
 margin := BlInsets right: inset.
 conversationPane margin = margin ifFalse: [ conversationPane margin: margin ].
 (activityPane width - desired) abs > 0.5 ifTrue: [ activityPane hExact: desired ].
 activityPane visibility: (visible ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ]).
 activityPane border: (BlBorder paint: (Color gray: 0.89) width: (narrow ifTrue: [ 1 ] ifFalse: [ 0 ])).
 splitterElement visibility: ((visible and: [ narrow not ]) ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ]).
 margin := BlInsets right: (desired - 4 max: 0).
 splitterElement margin = margin ifFalse: [ splitterElement margin: margin ]'.
ui compile: 'viewportWidth
 bodyPane ifNil: [ ^ nil ].
 ^ bodyPane width > 0 ifTrue: [ bodyPane width ] ifFalse: [ nil ]'.
ui class compile: 'featureVersion ^ 22'.
ui class compile: 'openConversation
 | view |
 (Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ]) ifFalse: [ self error: ''请使用桌面织境入口打开界面'' ].
 view := Smalltalk globals at: #LoomConversationWindow ifAbsent: [ nil ].
 view ifNil: [ view := self new. Smalltalk globals at: #LoomConversationWindow put: view ].
 ^ view show'.
ui := (Object << #LMConversationUI slots: slots; package: 'Loom-Interface') install.
"Use the native chat position and icon for Loom; do not expose a second chat."
GtWorldElement compile: 'gtWorldChatRegistryActionFor: anAction
 <gtWorldAction>
 ^ anAction noAction'.
GtWorldElement compile: 'loomConversationActionFor: anAction
 <gtWorldAction>
 ^ anAction explicit priority: 35; stencil: [
  BrButton new
   id: #loomConversationEntry;
   aptitude: BrGlamorousButtonWithIconAptitude - BrGlamorousButtonExteriorAptitude - BrGlamorousButtonWithLabelTooltipAptitude2;
   icon: BrGlamorousVectorIcons emphasizedChat;
   label: (''打开对话'' asRopedText fontName: ''Microsoft YaHei UI'');
   addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [
    BrLabel new
     aptitude: (BrGlamorousLabelAptitude new fontName: ''Microsoft YaHei UI''; yourself);
     text: ''打开对话''; padding: (BlInsets all: 5); yourself ]);
   action: [ LoomConversation open ]; yourself ]'.
'GT native Markdown conversation installed'
