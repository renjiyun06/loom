"Native conversation regression. Never invokes a model or executes Markdown code."
| report checks check ui view first raw code fence marker text row descriptor one two before payload result bytes model splitter divider pane space footer send attach hovered focus applyStyle offset editor shortcut |
report := Dictionary new.
checks := OrderedCollection new.
check := [ :condition :name | condition ifFalse: [ self error: name ]. checks add: name ].
[
 fence := String new: 3 withAll: (Character value: 96).
 text := LMChatStyle inlineText: '**粗体** 和 ', (String with: (Character value: 96)), 'code', (String with: (Character value: 96)), ' 与 [链接](https://example.com)'.
 check value: text asString = '粗体 和 code 与 链接' value: 'inline Markdown renders without source markers'.
 view := LMMarkdownView new.
 raw := '第一段', String cr, String cr, '正在生成'.
 view text: raw.
 first := view children first.
 view text: raw, '更多内容'.
 check value: view children first == first value: 'streaming preserves completed block widgets'.
 check value: view source = (raw, '更多内容') value: 'streaming preserves exact source'.
 marker := ('LoomMarkdownNoEval', UUID new asString copyWithout: $-) asSymbol.
 code := 'Smalltalk globals at: #', marker asString, ' put: true.'.
 view text: '# 标题', String cr, String cr,
 '| A | B |', String cr, '| --- | --- |', String cr, '| 中文 | 值 |', String cr, String cr,
 '- 第一项', String cr, '> 引用', String cr, String cr, fence, 'smalltalk', String cr, code.
 check value: ((view instVarNamed: 'specs') collect: #first) = #(#heading #table #list #quote #code) value: 'headings tables lists quotes and partial fences render'.
 check value: (Smalltalk globals includesKey: marker) not value: 'code blocks never execute Smalltalk'.
 check value: (LMChatStyle tableCells: '| a || b |') = #('a' '' 'b') value: 'empty table cells keep their columns'.
 check value: (LMChatStyle tableCells: '| a\|b | c |') = #('a|b' 'c') value: 'escaped pipes stay inside table cells'.
 check value: (LMChatStyle tableCells: '| D:\Loom | 路径 |') = #('D:\Loom' '路径') value: 'Windows paths retain backslashes inside tables'.
 ui := LMConversationUI new build.
 space := ui presentationSpace.
 footer := (ui instVarNamed: 'status') parent.
 send := footer children last.
 attach := footer childNamed: #loomPickAttachments.
 hovered := BlElementState hovered.
 focus := BlElementState focused.
 applyStyle := [ :button | space doStyle: button; doComputePropertiesFromRoot: button ].
 send enable.
 send states addState: hovered.
 applyStyle value: send.
 check value: send background paint color = (Color gray: 0.25)
  value: 'send button uses its hover background'.
 send states addState: focus; removeState: hovered.
 applyStyle value: send.
 check value: ((send background isKindOf: BlPaintBackground)
  and: [ send background paint color = (Color gray: 0.2) ])
  value: 'send button stays visible when hover leaves while it is focused'.
 send states removeState: focus.
 applyStyle value: send.
 check value: send background paint color = (Color gray: 0.2)
  value: 'send button restores its default background after a hover'.
 attach states addState: hovered.
 applyStyle value: attach.
 check value: attach background paint color = (Color gray: 0.95)
  value: 'attachment button uses its light hover background'.
 attach forceLayout.
 offset := attach children first bounds center - (attach extent / 2).
 check value: (offset x abs < 0.01 and: [ offset y abs < 0.01 ])
  value: 'the paperclip is centered horizontally and vertically in the hover background'.
 check value: (attach aptitude hasActorOfKind: BrGlamorousWithExplicitTooltipAptitude) not
  value: 'the attachment picker has no hover tooltip'.
 attach states removeState: hovered.
 applyStyle value: attach.
 check value: attach background isTransparent
  value: 'attachment button restores its transparent background'.
 row := LMConversationActivityView new controller: ui; yourself.
 one := Dictionary new at: 'id' put: 'activity-one'; at: 'type' put: 'dynamicToolCall';
  at: 'tool' put: 'pharo_eval'; at: 'status' put: 'completed'; at: 'success' put: true;
  at: 'arguments' put: (Dictionary new at: 'code' put: '1 + 1'; yourself);
  at: 'contentItems' put: { Dictionary new at: 'type' put: 'inputText'; at: 'text' put: '{"ok":true,"value":2}'; yourself };
  at: 'durationMs' put: 12; yourself.
 two := one copy at: 'id' put: 'activity-two'; yourself.
 row descriptor: one; toggle; showDetailMode: #result; descriptor: two; descriptor: one.
 check value: ((row instVarNamed: 'expanded') and: [ (row instVarNamed: 'mode') = #result ]) value: 'tool details survive row reuse'.
 before := LoomConversation orderedInputs size.
 payload := LoomConversationWindow collectUpdate.
 ui applyUpdate: payload.
 check value: (ui instVarNamed: 'historyItems') size = (payload at: 'messages') size value: 'message list loads real persisted conversation'.
 result := ui syncList: (ui instVarNamed: 'history') collection: (ui instVarNamed: 'historyItems') with: (payload at: 'messages').
 check value: result not value: 'unchanged messages do not rebind list rows'.
 ui applyUpdate: (payload copy at: 'status' put: '正在处理'; at: 'processing' put: true; at: 'sendAllowed' put: false; yourself).
 check value: (ui instVarNamed: 'status') text asString = 'Enter 发送 · Shift Enter 换行'
  value: 'composer keeps shortcuts while processing'.
 check value: send states isDisabled value: 'the send button is disabled while processing'.
 editor := ui instVarNamed: 'input'.
 shortcut := editor editor editorShortcuts
  detectShortcutLike: (BrEditorShortcut new combination: BlKeyCombination return; yourself)
  ifPresent: [ :item | item ] ifAbsent: [ nil ].
 editor text: '仍可修改的草稿'.
 (shortcut instVarNamed: #performBlock) value.
 check value: (editor text asString = '仍可修改的草稿' and: [ (ui instVarNamed: 'composerBusy') ~= true ])
  value: 'Enter leaves typed text in the composer while processing'.
 check value: ((ui instVarNamed: 'status') parent children size = 4
  and: [ (LMConversationUI includesSelector: #cancelCurrentTurn) not ])
  value: 'composer has no stop button or action'.
 ui applyUpdate: (payload copy at: 'status' put: '本轮未完成'; at: 'processing' put: false; yourself).
 check value: (ui instVarNamed: 'status') text asString = '本轮未完成'
  value: 'composer still shows failure status'.
 check value: (LoomConversation orderedInputs size = before) value: 'UI validation submits no model request'.
 check value: shortcut name = 'Send Loom message'
  value: 'Enter shortcut remains installed'.
 shortcut := editor editor editorShortcuts
  detectShortcutLike: (BrEditorShortcut new combination: BlKeyCombination primaryV; yourself)
  ifPresent: [ :item | item ] ifAbsent: [ nil ].
 check value: (shortcut notNil and: [ shortcut name = 'Paste Loom attachments or text' ])
  value: 'the composer handles attachment paste through the regular paste shortcut'.
 check value: ((LoomConversationWindow instVarNamed: 'poller') isTerminated not) value: 'live background event reader remains active'.
 check value: ((LoomConversationWindow instVarNamed: 'bodyPane') userData at: #activityTimeline) class = LMActivityReader
  value: 'live activity reads a SQLite-backed page'.
 splitter := LoomConversationWindow instVarNamed: #splitterElement.
 divider := splitter children first.
 splitter dispatchEvent: (BlMouseEnterEvent new target: splitter; yourself).
 check value: divider background paint color = (Color gray: 0.66)
  value: 'live splitter handles mouse enter'.
 splitter dispatchEvent: (BlMouseLeaveEvent new target: splitter; yourself).
 check value: divider background isTransparent
  value: 'the divider is hidden after the mouse leaves'.
 pane := LoomConversationWindow instVarNamed: #activityPane.
 check value: (pane border isVisible not and: [ (pane childNamed: #loomActivityToolbar) border isVisible not ])
  value: 'the activity pane and toolbar have no side borders'.
 check value: (pane childNamed: #loomActivityToolbarRule) height = 1
  value: 'the toolbar keeps its horizontal rule'.
 model := LMConversationStream new requestId: 'interrupted-test'; yourself.
 model acceptEnvelope: (Dictionary new at: 'direction' put: 'server'; at: 'at' put: DateAndTime now asString;
  at: 'message' put: (Dictionary new at: 'method' put: 'item/started';
   at: 'params' put: (Dictionary new at: 'threadId' put: 'test-thread'; at: 'turnId' put: 'test-turn';
    at: 'item' put: (one copy at: 'status' put: 'inProgress'; yourself); yourself); yourself); yourself).
 model acceptEnvelope: (Dictionary new at: 'direction' put: 'server'; at: 'at' put: DateAndTime now asString;
  at: 'message' put: (Dictionary new at: 'method' put: 'turn/completed';
   at: 'params' put: (Dictionary new at: 'threadId' put: 'test-thread';
    at: 'turn' put: (Dictionary new at: 'id' put: 'test-turn'; at: 'status' put: 'interrupted'; yourself); yourself); yourself); yourself).
 check value: (model snapshot first at: 'status') = 'interrupted' value: 'interruption never labels an unfinished tool complete'.
 row descriptor: model snapshot first.
 check value: (row instVarNamed: 'duration') text asString = '中断' value: 'interrupted status is explicit in the native row'.
 row := LMConversationMessageView new controller: ui; yourself.
 descriptor := Dictionary new at: 'id' put: 'source-message'; at: 'role' put: 'assistant';
  at: 'text' put: '## 原始 Markdown'; at: 'pending' put: false; yourself.
 row descriptor: (descriptor copy at: 'pending' put: true; at: 'text' put: ''; yourself).
 check value: ((row instVarNamed: 'stateLabel') text asString = '正在处理…'
  and: [ (row instVarNamed: 'stateLabel') visibility class = BlVisibility visible class ])
  value: 'reply shows processing before text arrives'.
 row descriptor: (descriptor copy at: 'pending' put: true; yourself).
 check value: ((row instVarNamed: 'stateLabel') text asString = '正在回复…'
  and: [ (row instVarNamed: 'body') source = (descriptor at: 'text') ])
  value: 'reply shows streamed text and its progress label'.
 row descriptor: (descriptor copy at: 'ok' put: false; yourself).
 check value: ((row instVarNamed: 'stateLabel') text asString = '未完成'
  and: [ (row instVarNamed: 'stateLabel') visibility class = BlVisibility visible class ])
  value: 'an unsuccessful reply still displays its completion state'.
 row descriptor: descriptor; toggleSource;
  descriptor: (descriptor copy at: 'id' put: 'another-message'; yourself); descriptor: descriptor.
 check value: ((row instVarNamed: 'rawShown') and: [
  (row instVarNamed: 'body') text asString = (descriptor at: 'text') ])
  value: 'Markdown source mode survives message row reuse'.
 report at: 'ok' put: true; at: 'checks' put: checks asArray
] on: Error do: [ :error |
 report at: 'ok' put: false; at: 'error' put: error messageText; at: 'passed' put: checks asArray ].
report at: 'completedAt' put: DateAndTime now asString.
bytes := (STONJSON toString: report) utf8Encoded.
(ExperimentRoot / 'tests' / 'results' / 'native-chat-validation.json')
 binaryWriteStreamDo: [ :out | out nextPutAll: bytes; truncate: bytes size ].
report
