"Native conversation regression. Never invokes a model or executes Markdown code."
| report checks check ui view first raw code fence marker text row descriptor one two before payload result bytes model splitter divider pane space footer send attach hovered focus applyStyle offset editor shortcut running failed duration foreground |
report := Dictionary new.
checks := OrderedCollection new.
check := [ :condition :name | condition ifFalse: [ self error: name ]. checks add: name ].
[
 fence := String new: 3 withAll: (Character value: 96).
 text := LMChatStyle inlineText: '**粗体** 和 ', (String with: (Character value: 96)), 'code', (String with: (Character value: 96)), ' 与 [链接](https://example.com)'.
 check value: text asString = '粗体 和 code 与 链接' value: 'inline Markdown renders without source markers'.
 [ | markdown scripter paragraph point previous cursors left link right clicked |
  markdown := LMMarkdownView new text: 'Alpha [Link text](https://example.com) tail [unsupported](ftp://example.com)'; yourself.
  scripter := BlDevScripter new element: markdown; yourself.
  paragraph := (markdown allChildrenBreadthFirstSelect: [ :node | node isKindOf: BrTextEditorParagraphElement ]) first.
  point := [ :index | | start end |
   start := (paragraph globalCursorBoundsForIndex: index - 1) center.
   end := (paragraph globalCursorBoundsForIndex: index) center.
   start + ((end - start) / 3) ].
  previous := 0 @ 0.
  cursors := #(2 8 12 18 24) collect: [ :index | | next |
   next := point value: index.
   BlSpace simulateMouseMoveOn: markdown from: previous to: next.
   scripter pulse.
   previous := next.
   scripter space currentCursor class ].
  check value: cursors = { BlTextCursor. BlHandCursor. BlHandCursor. BlTextCursor. BlTextCursor }
   value: 'the hand cursor is confined to clickable Markdown link text'.
  left := point value: 2. link := point value: 8. right := point value: 18.
  clicked := false.
  ((paragraph text attributesAt: 8) detect: [ :attr | attr isKindOf: BrTextClickAttribute ])
   action: [ clicked := true ].
  BlSpace simulateMouseMoveOn: markdown from: previous to: link.
  scripter pulse.
  BlSpace simulateMouseDownOn: markdown at: link.
  BlSpace simulateMouseUpOn: markdown at: link.
  scripter pulse.
  check value: clicked value: 'clicking a hovered Markdown link still runs its action'.
  BlSpace simulateMouseMoveOn: markdown from: link to: left.
  BlSpace simulateMouseDownOn: markdown at: left.
  BlSpace simulateMouseMoveOn: markdown from: left to: right.
  BlSpace simulateMouseUpOn: markdown at: right.
  scripter pulse.
  check value: markdown children first editor hasSelection value: 'dragging across a link still selects text' ] value.
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
 [ | partial sealed tilde |
  partial := String cr join: { fence, 'mermaid'. 'sequenceDiagram'. 'A->>B: 你好' }.
  view text: partial.
  check value: (view children first isKindOf: LMChatMermaidBlock) not value: 'incomplete Mermaid remains a code block'.
  sealed := partial, String cr, fence.
  view text: sealed.
  check value: ((view children first isKindOf: LMChatMermaidBlock) and: [ view source = sealed ])
   value: 'closed Mermaid becomes a diagram and preserves the source'.
  tilde := String cr join: { '~~~Mermaid'. 'flowchart LR'. 'A --> B'. '~~~~' }.
  view text: tilde.
  check value: (view children first isKindOf: LMChatMermaidBlock) value: 'tilde Mermaid fences can use a longer closing fence' ] value.
 [ | tall diagram block card scripter thumbnail openButton |
  tall := Form extent: 80 @ 320 depth: 32.
  diagram := { tall. 320. 1280 }.
  block := LMChatMermaidBlock new hExact: 224; vFitContent; yourself.
  block showDiagram: diagram.
  scripter := BlDevScripter new element: block; yourself.
  scripter pulse.
  card := block childNamed: #loomMermaidPreview.
  thumbnail := card childNamed: #loomMermaidThumbnail.
  openButton := card childNamed: #loomMermaidOpenImage.
  check value: (thumbnail extent = (40 @ 160) and: [ card height < 200 ])
   value: 'tall Mermaid preview scales the entire diagram proportionally'.
  check value: (openButton parent == (card childNamed: #loomMermaidPreviewToolbar)
    and: [ openButton isKindOf: BrButton ])
   value: 'Mermaid uses a separate open button in its toolbar'.
  check value: ((block childNamed: #loomMermaidOpenStatus) visibility class = BlVisibility gone class)
   value: 'Mermaid opening feedback is hidden before the button is used'.
  block hExact: 82.
  scripter pulse; pulse.
  check value: (card width = 82 and: [ thumbnail extent = (40 @ 160) ])
   value: 'Mermaid preview fits a narrow message without cropping' ] value.
 check value: (LMChatStyle tableCells: '| a || b |') = #('a' '' 'b') value: 'empty table cells keep their columns'.
 check value: (LMChatStyle tableCells: '| a\|b | c |') = #('a|b' 'c') value: 'escaped pipes stay inside table cells'.
 check value: (LMChatStyle tableCells: '| D:\Loom | 路径 |') = #('D:\Loom' '路径') value: 'Windows paths retain backslashes inside tables'.
 ui := LMConversationUI new build.
 space := ui presentationSpace.
 [ | activityPane usage weekly contextLabel weeklyLabel toolbar notice |
  activityPane := ui instVarNamed: 'activityPane'.
  weekly := Dictionary new at: 'windowDurationMins' put: 10080; at: 'usedPercent' put: 5; yourself.
  usage := Dictionary new at: 'context' put: (Dictionary new at: 'recent' put: 80;
   at: 'window' put: 200; at: 'total' put: 900; yourself);
   at: 'weekly' put: weekly; yourself.
  ui updateCodexUsage: usage.
  toolbar := activityPane childNamed: #loomActivityToolbar.
  contextLabel := toolbar childNamed: #loomCodexContextUsage.
  weeklyLabel := toolbar childNamed: #loomCodexWeeklyUsage.
  check value: (contextLabel text asString = '上下文 40%' and: [ weeklyLabel text asString = '周剩余 95%' ])
   value: 'the toolbar displays thread context and remaining account quota'.
  check value: (contextLabel class = BrLabel and: [ weeklyLabel class = BrLabel ])
   value: 'usage values are ordinary non-interactive labels'.
  check value: (toolbar children first == contextLabel and: [ toolbar children second == weeklyLabel
   and: [ toolbar children last == (toolbar childNamed: #loomCodexSettings)
   and: [ (toolbar children at: 4) == (toolbar childNamed: #newCodexSession) ] ] ])
   value: 'the usage labels are on the left and the existing buttons are on the right'.
  ui updateCodexUsage: (usage copy at: 'context' put: nil; yourself).
  check value: (contextLabel text asString = '上下文 —' and: [ weeklyLabel text asString = '周剩余 95%' ])
   value: 'new threads show a pending context with the same weekly quota'.
  check value: (ui quotaRemainingLabel: (weekly copy at: 'usedPercent' put: 105; yourself)) = '周剩余 0%'
   value: 'remaining quota is zero after the account exceeds the allowance'.
  check value: (ui quotaRemainingLabel: nil) = '周剩余 —' value: 'missing quota has a placeholder'.
  notice := toolbar childNamed: #loomCodexToolbarNotice.
  ui codexSettingNotice: '等待执行…' in: notice.
  check value: contextLabel visibility class = BlVisibility gone class value: 'session notices have room in the toolbar'.
  ui codexSettingNotice: '' in: notice.
  check value: contextLabel visibility class = BlVisibility visible class value: 'usage returns after a session notice' ] value.
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
 running := Dictionary new at: 'id' put: 'command-failure'; at: 'type' put: 'commandExecution';
  at: 'command' put: 'fixture'; at: 'status' put: 'inProgress'; yourself.
 failed := running copy at: 'status' put: 'failed'; at: 'exitCode' put: 1; yourself.
 row descriptor: running; descriptor: failed.
 duration := row instVarNamed: 'duration'.
 foreground := [ :label |
  ((label text attributesAt: 1) detect: [ :attribute | attribute class = BlTextForegroundAttribute ]) paint ].
 check value: ((duration text asString = '失败' and: [ (foreground value: duration) = (Color r: 0.67 g: 0.19 b: 0.21) ])
  and: [ (row instVarNamed: 'expanded') not ]) value: 'failed commands show a red status and stay collapsed'.
 row descriptor: running; toggle; descriptor: failed.
 check value: ((row instVarNamed: 'expanded') and: [ (row instVarNamed: 'mode') = #arguments ])
  value: 'failed commands keep manually opened details and the selected tab'.
 row descriptor: one.
 check value: (foreground value: (row instVarNamed: 'duration')) = (Color gray: 0.55)
  value: 'a reused row displays the normal color for a successful tool'.
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
 row descriptor: (descriptor copy at: 'status' put: '浏览器关闭未确认'; yourself).
 check value: ((row instVarNamed: 'stateLabel') text asString = '浏览器关闭未确认'
  and: [ (row instVarNamed: 'body') source = (descriptor at: 'text') ])
  value: 'unconfirmed browser cleanup keeps the original reply visible'.
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
