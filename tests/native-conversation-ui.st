"Native conversation regression. Never invokes a model or executes Markdown code."
| report checks check ui view first raw code fence marker text row descriptor one two before payload result bytes model splitter divider |
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
 check value: (LoomConversation orderedInputs size = before) value: 'UI validation submits no model request'.
 check value: ((ui instVarNamed: 'input') editor editorShortcuts
  detectShortcutLike: (BrEditorShortcut new combination: BlKeyCombination return; yourself)
  ifPresent: [ :shortcut | shortcut name = 'Send Loom message' ] ifAbsent: [ false ])
  value: 'Enter shortcut remains installed'.
 check value: ((LoomConversationWindow instVarNamed: 'poller') isTerminated not) value: 'live background event reader remains active'.
 check value: ((LoomConversationWindow instVarNamed: 'bodyPane') userData at: #activityTimeline) class = LMActivityReader
  value: 'live activity reads a SQLite-backed page'.
 splitter := LoomConversationWindow instVarNamed: #splitterElement.
 divider := splitter children first.
 splitter dispatchEvent: (BlMouseEnterEvent new target: splitter; yourself).
 check value: divider background paint color = (Color gray: 0.66)
  value: 'live splitter handles mouse enter'.
 splitter dispatchEvent: (BlMouseLeaveEvent new target: splitter; yourself).
 check value: divider background paint color = (Color gray: 0.91)
  value: 'live splitter handles mouse leave'.
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
