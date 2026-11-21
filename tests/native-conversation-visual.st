"Visual checks for the compact native conversation interface."
| report checks check ui card body editor text entry row values list bytes before |
report := Dictionary new. checks := OrderedCollection new.
check := [ :condition :name | condition ifFalse: [ self error: name ]. checks add: name ].
[
 before := LoomConversation orderedInputs size.
 ui := LMConversationUI new build.
 ui layoutComposerForWidth: 1120.
 check value: ((ui instVarNamed: 'composerPane') margin left - 38) abs < 1
  value: 'composer uses the wider centered reading width'.
 (ui instVarNamed: 'input') text: '输入测试'.
 ui resizeComposer.
 check value: ((ui instVarNamed: 'placeholderLabel') visibility class = BlVisibility gone class)
  value: 'placeholder disappears while typing'.
 (ui instVarNamed: 'input') text: ''.
 ui resizeComposer.
 check value: ((ui instVarNamed: 'placeholderLabel') visibility class = BlVisibility visible class)
  value: 'placeholder returns after clearing the input'.
 text := '第一行', String cr, '第二行', String cr, '第三行'.
 editor := LMChatStyle readOnly: text size: 14.
 editor hExact: 400; forceLayout.
 check value: editor height >= 72 value: 'native line boxes match compact CSS reading rhythm'.
 card := LMConversationMessageView new hExact: 1000; yourself.
 card descriptor: (Dictionary new at: 'id' put: 'short-bubble'; at: 'role' put: 'user';
  at: 'text' put: '你好'; at: 'createdAt' put: DateAndTime now asUTC asString; yourself).
 card forceLayout; forceLayout.
 body := card instVarNamed: 'body'.
 check value: body parent width < 120 value: 'short user bubbles hug their content'.
 check value: ((card instVarNamed: 'userMetadataLabel') text asString includes: $:)
  value: 'user metadata shows local message time'.
 entry := Dictionary new at: 'id' put: 'visual-tool'; at: 'type' put: 'dynamicToolCall';
  at: 'tool' put: 'pharo_eval'; at: 'status' put: 'completed'; at: 'success' put: true;
  at: 'arguments' put: (Dictionary new at: 'code' put: '1 + 1'; yourself); at: 'durationMs' put: 12; yourself.
 row := LMConversationActivityView new controller: ui; hExact: 340; yourself.
 row descriptor: entry; forceLayout.
 check value: ((row instVarNamed: 'mark') allChildrenBreadthFirstSelect: [:child | child geometry isKindOf: BlSvgPath]) notEmpty
  value: 'completed tools use a vector status mark without missing font glyphs'.
 values := (LoomConversationWindow instVarNamed: 'lastPayload') at: 'activities'.
 values do: [ :value |
  row := LMConversationActivityView new controller: ui; hExact: 340; yourself.
  row descriptor: value; forceLayout ].
 checks add: 'every real activity entry binds and lays out successfully'.
 row := LMConversationActivityView new controller: ui; hExact: 340; yourself.
 ui bindActivityRow: row item: Dictionary new.
 check value: row children notEmpty value: 'malformed activity keeps a visible fallback without breaking list binding'.
 card := LMConversationMessageView new controller: ui; hExact: 1000; yourself.
 ui bindMessageRow: card item: Dictionary new.
 check value: card children notEmpty value: 'malformed message keeps a copyable fallback without breaking list binding'.
 list := (LoomConversationWindow instVarNamed: 'activity') childNamed: #scrollable.
 check value: (list instVarNamed: 'layoutOrScrollCounter') = 0
  value: 'live activity viewport has no interrupted layout transaction'.
 (((LoomConversationWindow instVarNamed: 'activityPane') visibility class = BlVisibility visible class) and: [
  (LoomConversationWindow instVarNamed: 'activityItems') notEmpty ]) ifTrue: [
  check value: list children notEmpty value: 'live activity viewport materializes visible rows' ].
 check value: (LoomConversation orderedInputs size = before) value: 'visual checks send no model request'.
 report at: 'ok' put: true; at: 'checks' put: checks asArray
] on: Error do: [ :error | report at: 'ok' put: false; at: 'error' put: error messageText; at: 'passed' put: checks asArray ].
report at: 'completedAt' put: DateAndTime now asString.
bytes := (STONJSON toString: report) utf8Encoded.
(ExperimentRoot / 'tests' / 'results' / 'native-chat-visual-validation.json')
 binaryWriteStreamDo: [ :out | out nextPutAll: bytes; truncate: bytes size ].
report
