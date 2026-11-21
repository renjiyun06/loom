"Verify prototype interactions using independent native widgets and persisted state read-only. Run on the UI queue."
| ui root viewport panel table data empty history last oldCount checks verify result receipt top activity activityViewport events preceding |
checks := OrderedCollection new.
verify := [ :condition :message | condition ifFalse: [ self error: message ]. checks add: message ].
result := [
 oldCount := LoomConversation orderedInputs size.
 ui := LMConversationUI new build.
 root := ui instVarNamed: 'root'.
 root hExact: 760; vExact: 700; forceLayout; forceLayout.
 verify value: ((ui instVarNamed: 'activityPane') visibility class = BlVisibility gone class) value: '760 wide viewport starts with its activity overlay closed'.
 ui toggleActivityPane. root requestLayout; forceLayout.
 verify value: ((ui instVarNamed: 'conversationPane') width = 760 and: [ (ui instVarNamed: 'activityPane') width = 380 ]) value: '760 wide overlay preserves full reading width'.
 ui toggleActivityPane. root forceLayout.
 verify value: ((ui instVarNamed: 'activityPane') visibility class = BlVisibility gone class) value: 'activity overlay hides on request'.
 ui toggleActivityPane. root hExact: 1493; forceLayout.
 (ui instVarNamed: 'bodyPane') requestLayout.
 root requestLayout; forceLayout.
 verify value: ((ui instVarNamed: 'conversationPane') width = 1121) value: 'wide layout returns to a separate 368 wide sidebar'.
 activity := ui instVarNamed: 'activity'.
 panel := ui instVarNamed: 'activityPane'.
 empty := activity userData at: #emptyLabel.
 verify value: (panel children size = 3 and: [ panel children first == activity and: [ panel children second == empty ] ])
  value: 'the sidebar contains the activity list, empty state, and settings control'.
 verify value: (activity boundsInParent top = 34 and: [ activity boundsInParent bottom = panel height ])
  value: 'the activity list fills the sidebar below the settings control'.
 panel := LMChatStyle codePanel: (String new: 170 withAll: $x) language: 'text'.
 panel hExact: 350; forceLayout; forceLayout.
 viewport := panel children last childNamed: #scrollable.
 verify value: (viewport scrolledElement width > 1000 and: [ viewport width = 350 ]) value: 'long code is clipped inside its own viewport'.
 viewport scrollBy: 80@0.
 verify value: viewport scrollPosition x < 0 value: 'long code scrolls horizontally'.
 table := LMChatStyle table: { #table. #('A' 'B' 'C' 'D' 'E'). { #('1' '2' '3' '4' '5') } }.
 table hExact: 350; forceLayout; forceLayout.
 viewport := table childNamed: #scrollable.
 viewport scrollBy: 80@0.
 verify value: (viewport scrolledElement width = 500 and: [ viewport scrollPosition x < 0 ]) value: 'a wide table keeps a minimum column width and scrolls'.
 data := Dictionary new at: 'messages' put: ((1 to: 30) collect: [ :i |
  Dictionary new at: 'id' put: 'fixture-', i asString; at: 'role' put: 'assistant'; at: 'text' put: '测试滚动锚点'; yourself ]);
  at: 'activities' put: #(); at: 'status' put: '已完成'; at: 'processing' put: false; at: 'elapsed' put: 0; yourself.
 ui instVarNamed: 'followOutput' put: false.
 ui applyUpdate: data. root forceLayout; forceLayout.
 verify value: (empty text asString = '暂无活动') value: 'the empty activity panel has a session-independent message'.
 history := ui instVarNamed: 'history'.
 viewport := history childNamed: #scrollable.
 top := viewport layout findFirstVisibleChildClosestToStartCompletelyVisible: false acceptPartiallyVisible: true.
 last := (data at: 'messages') last.
 last at: 'text' put: '新内容'.
 data at: 'messages' put: ((data at: 'messages') allButLast copyWith: last copy).
 ui applyUpdate: (data copy at: 'messages' put: ((data at: 'messages') copyWith: (last copy at: 'id' put: 'fixture-new'; yourself)); yourself).
 root forceLayout.
 verify value: ((ui instVarNamed: 'followButton') visibility class = BlVisibility visible class and: [ top == (viewport layout findFirstVisibleChildClosestToStartCompletelyVisible: false acceptPartiallyVisible: true) ]) value: 'updates announce new content without moving an earlier reading position'.
 history scrollToIndex: (ui instVarNamed: 'historyItems') size - 12.
 root forceLayout; forceLayout.
 verify value: viewport canScrollDown value: 'the test scroll starts above the bottom'.
 viewport scrollBy: 0@10000.
 verify value: viewport canScrollDown not value: 'the list actually reaches its bottom'.
 verify value: ((ui instVarNamed: 'followOutput') and: [ (ui instVarNamed: 'followButton') visibility class = BlVisibility gone class ]) value: 'the actual scroll event resumes following and clears the jump button'.
 events := (1 to: 30) collect: [ :index |
  Dictionary new at: 'id' put: 'activity-', index asString;
   at: 'type' put: (index even ifTrue: [ 'dynamicToolCall' ] ifFalse: [ 'agentMessage' ]);
   at: 'text' put: 'Progress'; at: 'status' put: (index = 30 ifTrue: [ 'failed' ] ifFalse: [ 'completed' ]); yourself ].
 ui applyUpdate: (data copy at: 'activities' put: events; yourself).
 root forceLayout; forceLayout.
 verify value: ((ui instVarNamed: 'activityItems') asArray = events and: [ empty visibility class = BlVisibility gone class ])
  value: 'progress, tool, and failed entries are shown together in order'.
 activityViewport := activity childNamed: #scrollable.
 activityViewport scrollBy: 0@100.
 verify value: (activityViewport canScrollDown and: [ (ui instVarNamed: 'activityFollow') not ])
  value: 'scrolling short of the latest activity pauses following'.
 activityViewport scrollBy: 0@10000.
 verify value: (activityViewport canScrollDown not and: [ ui instVarNamed: 'activityFollow' ])
  value: 'reaching the bottom resumes following without a footer control'.
 activityViewport scrollBy: 0 @ -10000.
 verify value: ((ui instVarNamed: 'activityFollow') not) value: 'scrolling to the top pauses following'.
 preceding := (events first: 5) collect: [:entry | entry copy at: 'id' put: 'older-', (entry at: 'id'); yourself].
 ui applyUpdate: (data copy at: 'activities' put: preceding, events; yourself).
 verify value: ((ui instVarNamed: 'activityItems') asArray = (preceding, events))
  value: 'earlier activities prepend without losing or duplicating recent activities'.
 verify value: LoomConversation orderedInputs size = oldCount value: 'no model request or message was created'.
 Dictionary new at: 'ok' put: true; at: 'checks' put: checks asArray; yourself
] on: Error do: [ :error | Dictionary new at: 'ok' put: false; at: 'error' put: error description; at: 'passed' put: checks asArray; yourself ].
receipt := ExperimentRoot / 'tests' / 'results' / 'conversation-prototype' / 'native-behavior.json'.
receipt writeStreamDo: [ :out | out nextPutAll: (STONJSON toString: result); truncate: out position ].
result
