"System activity uses the same data and row details as the conversation sidebar."
| ui row |
row := (BrVerticalPane << #LMActivityOverviewRow slots: #(caption entry); package: 'Loom-Interface') install.
row compile: 'initialize
 super initialize.
 self hMatchParent; vFitContent; padding: (BlInsets top: 6 right: 8 bottom: 5 left: 8).
 caption := LMChatStyle label: '''' size: 11.
 caption aptitude foreground: (Color gray: 0.48).
 caption margin: (BlInsets left: 6).
 entry := LMConversationActivityView new.
 self addChildren: { caption. entry }'.
row compile: 'controller: controller entry controller: controller'.
row compile: 'descriptor: record
 | stamp session |
 session := record at: ''sessionId''.
 stamp := record at: ''at'' ifAbsent: [ nil ].
 stamp := stamp ifNil: [ '''' ] ifNotNil: [
  [ ((DateAndTime fromString: stamp) asLocal asString first: 16) copyReplaceAll: ''T'' with: '' '' ]
   on: Error do: [ :error | '''' ] ].
 caption text: session, (stamp isEmpty ifTrue: [ '''' ] ifFalse: [ ''    '', stamp ]).
 [ entry descriptor: record ] on: Error do: [ :error | entry showRenderingError: error descriptor: record ]'.

ui := (Object << #LMActivityOverviewUI
 slots: #(space world filters list older status reader poller sessionIds selected limit currentPage follow expansions detailModes);
 package: 'Loom-Interface') install.
ui class compile: 'open
 | view |
 view := Smalltalk globals at: #LoomActivityOverviewWindow ifAbsentPut: [ self new ].
 ^ view showIn: (Smalltalk globals at: #LoomDesktopWorld)'.
ui compile: 'tab
 (space isNil or: [ world isNil ]) ifTrue: [ ^ nil ].
 ^ world tabGroup tabs detect: [ :each | each model == space ] ifNone: [ nil ]'.
ui compile: 'showIn: targetWorld
 world := targetWorld.
 self tab ifNil: [
  space := BlSpace new title: ''运行活动''; yourself.
  self build.
  world showSpace: space ].
 self tab select.
 self startPolling.
 ^ self'.
ui compile: 'restoreIn: targetWorld
 poller ifNotNil: [ poller terminate. poller := nil ].
 world := targetWorld.
 self tab ifNotNil: [ self build. self startPolling ]'.
ui compile: 'build
 | root side region toolbar viewport |
 reader := LMActivityReader new channel: ''overview''; yourself.
 sessionIds ifNil: [ sessionIds := #() ].
 expansions ifNil: [ expansions := Dictionary new ].
 detailModes ifNil: [ detailModes := Dictionary new ].
 limit ifNil: [ limit := 100 ].
 currentPage := nil.
 follow := true.
 root := BrHorizontalPane new id: #loomActivityOverview; matchParent; background: Color white; yourself.
 filters := BrVerticalPane new hMatchParent; vFitContent; padding: (BlInsets all: 12); yourself.
 side := BrScrollPane new id: #loomActivityFilters; vMatchParent; hExact: 215;
  aptitude: BrScrollPaneAptitude new + BrGlamorousWithVerticalScrollbarAptitude new;
  content: filters;
  border: (BlBorder paint: (Color gray: 0.91) width: 1); yourself.
 region := BrVerticalPane new matchParent; padding: (BlInsets all: 12); yourself.
 toolbar := BrHorizontalPane new hMatchParent; vExact: 34; alignCenterLeft; yourself.
 toolbar layout cellSpacing: 8.
 older := LMChatStyle button: ''加载更早'' action: [ self loadOlder ].
 older id: #loomLoadOlderActivity; enabled: false.
 status := (LMChatStyle label: ''正在读取活动…'' size: 12) hMatchParent; yourself.
 status aptitude foreground: (Color gray: 0.48).
 toolbar addChildren: { older. status }.
 list := BrSimpleList new id: #loomActivities; matchParent;
  itemType: [ :factory :item :index | LMActivityOverviewRow ];
  itemStencil: [ LMActivityOverviewRow new controller: self; yourself ];
  itemDataBinder: [ :row :item :index | row descriptor: item ];
  items: #(); yourself.
 viewport := list childNamed: #scrollable.
 viewport addEventHandlerOn: BlElementScrolledEvent do: [ :event |
  (event target == viewport eventDispatcher and: [ event delta y isZero not ])
   ifTrue: [ follow := viewport canScrollDown not ] ].
 region addChildren: { toolbar. list }.
 root addChildren: { side. region }.
 space root removeChildren; addChild: root.
 self renderFilters'.
ui compile: 'renderFilters
 filters removeChildren.
 filters addChild: (LMChatStyle label: ''会话'' size: 14).
 filters addChild: (self filter: nil caption: ''全部会话'').
 sessionIds do: [ :id | filters addChild: (self filter: id caption: id) ]'.
ui compile: 'filter: id caption: caption
 ^ ((LMChatStyle button: caption action: [ self selectSession: id ]
  foreground: (Color gray: 0.25) background: (id = selected ifTrue: [ Color gray: 0.9 ] ifFalse: [ Color white ]))
  hMatchParent; vExact: 30; yourself)'.
ui compile: 'selectSession: id
 selected = id ifTrue: [ ^ self ].
 selected := id.
 currentPage := nil.
 limit := 100.
 follow := true.
 list items: #().
 status text: ''正在读取活动…''.
 older enabled: false.
 self renderFilters'.
ui compile: 'startPolling
 (poller notNil and: [ poller isTerminated not ]) ifTrue: [ ^ self ].
 poller := [ | nextSessions |
  nextSessions := DateAndTime now.
  [ self tab notNil ] whileTrue: [
   [ (STONJSON fromString: (BridgeIPC / ''bridge-ready.json'') contents) at: ''status'' ] value = ''ready'' ifTrue: [
    DateAndTime now >= nextSessions ifTrue: [
     self refreshSessions.
     nextSessions := DateAndTime now + 2 seconds ].
    self refreshActivities ].
   (Delay forMilliseconds: 220) wait ]
 ] fork.
 poller name: ''Loom activity overview refresh'' '.
ui compile: 'defer: operation
 world enqueueTask: (BlTaskAction new action: [
  self tab ifNotNil: [ operation value ] ]; yourself)'.
ui compile: 'refreshSessions
 [ | ids |
  ids := (LoomSessions list collect: [ :session | session at: ''id'' ]) asArray.
  ids = sessionIds ifFalse: [
   self defer: [ sessionIds := ids. self renderFilters ] ]
 ] on: Error do: [ :error | self defer: [ status text: error messageText ] ]'.
ui compile: 'refreshActivities
 [ | page selectedId readerAtRequest |
  selectedId := selected.
  readerAtRequest := reader.
  page := readerAtRequest pageOf: limit focus: nil session: selectedId.
  (page notNil and: [ page ~~ currentPage ]) ifTrue: [
   self defer: [
    (reader == readerAtRequest and: [ selected = selectedId and: [ (page at: ''session'') = selectedId ] ])
     ifTrue: [ self apply: page ] ] ]
 ] on: Error do: [ :error | self defer: [ status text: error messageText ] ]'.
ui compile: 'loadOlder
 (currentPage notNil and: [ (currentPage at: ''older'') and: [ (currentPage at: ''limit'') = limit ] ]) ifTrue: [
  follow := false.
  limit := limit + 100.
  older enabled: false ]'.
ui compile: 'apply: page
 | incoming anchor index widget |
 page == currentPage ifTrue: [ ^ self ].
 incoming := page at: ''items''.
 anchor := follow ifFalse: [ self visibleAnchor ].
 currentPage := page.
 list items: incoming.
 older enabled: (page at: ''older'').
 status text: (incoming
  ifEmpty: [ ''这个会话范围暂无活动'' ]
  ifNotEmpty: [ incoming size asString, '' 条已加载活动'' ]).
 incoming ifEmpty: [ ^ self ].
 index := follow ifTrue: [ incoming size ] ifFalse: [
  anchor ifNil: [ 0 ] ifNotNil: [ incoming findFirst: [ :item | (item at: ''id'') = anchor first ] ] ].
 index > 0 ifTrue: [
  widget := list.
  (widget childNamed: #scrollable) enqueueTask: (BlDelayedTaskAction new delay: 40 milliSeconds; action: [
   (currentPage == page and: [ list == widget ]) ifTrue: [
    anchor ifNil: [ widget scrollToIndex: index ]
     ifNotNil: [ widget scrollToIndex: index offset: anchor second ] ] ]; yourself) ]'.
ui compile: 'visibleAnchor
 | viewport child holder index values |
 currentPage ifNil: [ ^ nil ].
 values := currentPage at: ''items''.
 viewport := list childNamed: #scrollable.
 child := viewport layout findFirstVisibleChildClosestToStartCompletelyVisible: false acceptPartiallyVisible: true.
 child ifNil: [ ^ nil ].
 holder := viewport elementHolderOf: child.
 index := holder layoutPosition.
 (index between: 1 and: values size) ifFalse: [ ^ nil ].
 ^ { (values at: index) at: ''id''. child boundsInParent top }'.
ui compile: 'activityExpandedFor: id ^ expansions at: id ifAbsent: [ false ]'.
ui compile: 'activityExpanded: value for: id expansions at: id put: value'.
ui compile: 'activityDetailModeFor: id ^ detailModes at: id ifAbsent: [ #arguments ]'.
ui compile: 'activityDetailMode: value for: id detailModes at: id put: value'.
GtWorldElement compile: 'loomActivityOverviewActionFor: anAction
 <gtWorldAction>
 ^ anAction explicit priority: 37; stencil: [
  (LMChatStyle replyAction: #loomActivityOverviewEntry icon: ''activity'' action: [ LMActivityOverviewUI open ])
   addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [ LMChatStyle label: ''运行活动'' size: 12 ]);
   yourself ]'.
'Loom system activity tab installed'
