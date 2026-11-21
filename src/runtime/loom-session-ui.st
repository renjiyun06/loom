"System-level Loom session management in a GT tab."
| ui |
ui := (Object << #LMSessionManagerUI
 slots: #(space world list detail notice identifier records selected poller busy);
 package: 'Loom-Interface') install.
ui class compile: 'open
 | view |
 view := Smalltalk globals at: #LoomSessionManagerWindow ifAbsentPut: [ self new ].
 ^ view showIn: (Smalltalk globals at: #LoomDesktopWorld)'.
ui compile: 'tab
 (world isNil or: [ space isNil ]) ifTrue: [ ^ nil ].
 ^ world tabGroup tabs detect: [ :each | each model == space ] ifNone: [ nil ]'.
ui compile: 'showIn: targetWorld
 | tab |
 world := targetWorld.
 tab := self tab.
 tab ifNil: [
  busy := false.
  space := BlSpace new title: ''会话管理''; yourself.
  self build.
  world showSpace: space.
  tab := self tab ].
 tab select.
 world requestNextPulse.
 self startPolling.
 ^ self'.
ui compile: 'restoreIn: targetWorld
 poller ifNotNil: [ poller terminate. poller := nil ].
 busy := false.
 world := targetWorld.
 self tab ifNotNil: [ self build. self startPolling ].
 ^ self'.
ui compile: 'build
 | root toolbar body previous |
 previous := identifier ifNil: [ '''' ] ifNotNil: [ identifier text asString ].
 root := BrVerticalPane new id: #loomSessionManager; matchParent; background: Color white;
  padding: (BlInsets all: 18); yourself.
 root layout cellSpacing: 12.
 toolbar := BrHorizontalPane new hMatchParent; vFitContent; alignCenterLeft; yourself.
 toolbar layout cellSpacing: 8.
 identifier := LMChatStyle editor: 13.
 identifier id: #loomSessionIdentifier; beEditable; hExact: 190; vExact: 30;
  padding: (BlInsets top: 5 right: 7 bottom: 5 left: 7);
  border: (BlBorder paint: (Color gray: 0.82) width: 1); text: previous.
 notice := (LMChatStyle label: '''' size: 12) hMatchParent; yourself.
 toolbar addChildren: {
  LMChatStyle label: ''会话标识'' size: 13.
  identifier.
  (LMChatStyle button: ''新建会话'' action: [ self register ]) id: #loomRegisterSession; yourself.
  notice }.
 body := BrHorizontalPane new matchParent; yourself.
 body layout cellSpacing: 18.
 list := BrVerticalPane new hMatchParent; vFitContent; yourself.
 detail := BrVerticalPane new hMatchParent; vFitContent; yourself.
 body addChildren: {
  (self scroll: list) id: #loomSessionList; hExact: 235; yourself.
  (self scroll: detail) id: #loomSessionDetail; hMatchParent; yourself }.
 root addChildren: { toolbar. body }.
 space root removeChildren; addChild: root.
 self render'.
ui compile: 'scroll: content
 ^ BrScrollPane new vMatchParent;
  aptitude: BrScrollPaneAptitude new + BrGlamorousWithVerticalScrollbarAptitude new;
  content: content; yourself'.
ui compile: 'startPolling
 (poller notNil and: [ poller isTerminated not ]) ifTrue: [ ^ self ].
 poller := [
  [ self tab notNil ] whileTrue: [
   self refresh.
   (Delay forSeconds: 1) wait ]
 ] fork.
 poller name: ''Loom session manager refresh'' '.
ui compile: 'defer: action
 world enqueueTask: (BlTaskAction new action: [
  self tab ifNotNil: [ action value ] ]; yourself)'.
ui compile: 'refresh
 [ | updated status |
  status := STONJSON fromString: (BridgeIPC / ''bridge-ready.json'') contents.
  (status at: ''status'') = ''ready'' ifFalse: [ ^ self ].
  updated := LoomSessions list.
  self defer: [
   records = updated ifFalse: [
    records := updated.
    selected ifNil: [ records ifNotEmpty: [ selected := records first at: ''id'' ] ].
    self render ] ]
 ] on: Error do: [ :error | self defer: [ notice text: error messageText ] ]'.
ui compile: 'render
 list removeChildren.
 list addChild: (LMChatStyle label: ''Loom 会话'' size: 15).
 records ifNotNil: [ records do: [ :record | list addChild: (self rowFor: record) ] ].
 self renderDetail'.
ui compile: 'rowFor: record
 | line name state |
 line := BrHorizontalPane new hMatchParent; vExact: 35; alignCenterLeft; yourself.
 name := record at: ''id''.
 state := self labelForState: (record at: ''runState'').
 line addChildren: {
  ((LMChatStyle button: name action: [ selected := name. self render ]
    foreground: (Color gray: 0.25) background: (selected = name ifTrue: [ Color gray: 0.9 ] ifFalse: [ Color white ]))
    hMatchParent; yourself).
  LMChatStyle label: state size: 12 }.
 ^ line'.
ui compile: 'renderDetail
 | record actions history running queued |
 detail removeChildren.
 records ifNil: [ ^ self ].
 record := records detect: [ :item | (item at: ''id'') = selected ] ifNone: [ nil ].
 record ifNil: [ ^ self ].
 detail addChild: (LMChatStyle label: selected size: 17).
 running := record at: ''runState''.
 detail addChild: (LMChatStyle label: (self labelForState: running) size: 13).
 (record at: ''call'') ifNotNil: [ :call |
  detail addChild: (LMChatStyle label: ''当前调用  '', (call at: ''requestId'') size: 12) ].
 queued := record at: ''queued''.
 queued ifNotEmpty: [
  detail addChild: (LMChatStyle label: ''排队调用  '', queued size asString size: 12) ].
 actions := BrHorizontalPane new hMatchParent; vExact: 40; alignCenterLeft; yourself.
 actions layout cellSpacing: 8.
 running = ''idle'' ifTrue: [
  actions addChild: ((LMChatStyle button: ''切换底层会话'' action: [ self rotate: (record at: ''id'') ])
   id: #loomRotateSession; yourself) ].
 (#(''queued'' ''running'') includes: running) ifTrue: [
  actions addChild: ((LMChatStyle button: ''停止'' action: [ self stop: (record at: ''id'') ])
   id: #loomStopSession; yourself) ].
 actions children ifNotEmpty: [ detail addChild: actions ].
 detail addChild: (LMChatStyle label: ''底层 Codex 会话'' size: 15).
 (record at: ''threadId'') ifNil: [
  detail addChild: (LMChatStyle label: ((record at: ''state'') = ''creating''
   ifTrue: [ running = ''running'' ifTrue: [ ''正在创建底层会话'' ] ifFalse: [ ''底层会话创建结果待确认'' ] ]
   ifFalse: [ ''下一次调用将创建底层会话'' ]) size: 12) ].
 history := record at: ''threads''.
 history reverseDo: [ :entry |
  detail addChild: (LMChatStyle label: ((entry at: ''current'') ifTrue: [ ''当前'' ] ifFalse: [ ''历史'' ]),
   ''  '', (entry at: ''threadId'') size: 13).
  detail addChild: (LMChatStyle label: (entry at: ''startedAt'') size: 12) ]'.
ui compile: 'labelForState: state
 | index |
 index := #(''idle'' ''queued'' ''running'' ''stopping'') indexOf: state ifAbsent: [ 1 ].
 ^ #(''空闲'' ''排队中'' ''运行中'' ''停止中'') at: index'.
ui compile: 'register
 | id |
 id := identifier text asString trimBoth.
 id isEmpty ifTrue: [ notice text: ''请输入会话标识''. ^ self ].
 self run: [ LoomSessions register: id ] completed: [
  selected := id.
  identifier text: ''''.
  self render.
  notice text: ''会话已登记'' ]'.
ui compile: 'rotate: id
 self run: [ LoomSessions rotate: id ] completed: [ notice text: ''已切换，下一次调用会创建新会话'' ]'.
ui compile: 'stop: id
 self run: [ LoomSessions stop: id ] completed: [ notice text: ''已发出停止请求'' ]'.
ui compile: 'run: operation completed: completed
 busy = true ifTrue: [ ^ self ].
 busy := true.
 [ | errorText |
  errorText := [ operation value. nil ] on: Error do: [ :error | error messageText ].
  self defer: [
   busy := false.
   errorText ifNil: [ completed value ] ifNotNil: [ notice text: errorText ] ].
  self refresh
 ] fork'.
GtWorldElement compile: 'loomSessionsActionFor: anAction
 <gtWorldAction>
 ^ anAction explicit priority: 36; stencil: [
  (LMChatStyle replyAction: #loomSessionManagerEntry icon: ''messages-square'' action: [ LMSessionManagerUI open ])
   addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [ LMChatStyle label: ''会话管理'' size: 12 ]);
   yourself ]'.
'Loom session manager tab installed'
