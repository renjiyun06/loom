"Display-only stream regression. Uses a fixture, never calls a model."
| model envelope start delta complete file bytes split before report failure |
report := Dictionary new.
[
 envelope := [ :method :params | Dictionary new
  at: 'direction' put: 'server'; at: 'at' put: '2026-11-21T00:00:00Z';
  at: 'message' put: (Dictionary new at: 'method' put: method; at: 'params' put: params; yourself); yourself ].
 start := envelope value: 'item/started' value: (Dictionary new
  at: 'threadId' put: 'thread-test'; at: 'turnId' put: 'turn-test';
  at: 'item' put: (Dictionary new at: 'id' put: 'answer'; at: 'type' put: 'agentMessage';
   at: 'phase' put: 'final_answer'; at: 'text' put: ''; yourself); yourself).
 delta := envelope value: 'item/agentMessage/delta' value: (Dictionary new
  at: 'threadId' put: 'thread-test'; at: 'turnId' put: 'turn-test';
  at: 'itemId' put: 'answer'; at: 'delta' put: '你好'; yourself).
 complete := envelope value: 'item/completed' value: (Dictionary new
  at: 'threadId' put: 'thread-test'; at: 'turnId' put: 'turn-test';
  at: 'item' put: (Dictionary new at: 'id' put: 'answer'; at: 'type' put: 'agentMessage';
   at: 'phase' put: 'final_answer'; at: 'text' put: '你好'; yourself); yourself).
 model := LMConversationStream new requestId: 'fixture'; yourself.
 file := ExperimentRoot / 'tests' / 'results' / 'conversation-stream-fixture.jsonl'.
 model instVarNamed: 'file' put: file.
 bytes := ((STONJSON toString: start), String lf, (STONJSON toString: delta), String lf) utf8Encoded.
 split := (bytes indexOf: 228) + 1.
 file binaryWriteStreamDo: [ :out | out nextPutAll: (bytes first: split); truncate: split ].
 model poll.
 model answerText isEmpty ifFalse: [ self error: 'Partial UTF8 line was rendered' ].
 file binaryWriteStreamDo: [ :out | out nextPutAll: bytes; truncate: bytes size ].
 model poll.
 model answerText = '你好' ifFalse: [ self error: 'Chinese delta lost or corrupt' ].
 before := model snapshot.
 model poll.
 model snapshot = before ifFalse: [ self error: 'Repeated read duplicated events' ].
 model acceptEnvelope: complete.
 model answerText = '你好' ifFalse: [ self error: 'Completed answer duplicated deltas' ].
 model acceptEnvelope: (envelope value: 'item/started' value: (Dictionary new
  at: 'threadId' put: 'thread-test'; at: 'turnId' put: 'turn-test';
  at: 'item' put: (Dictionary new at: 'id' put: 'progress'; at: 'type' put: 'agentMessage';
   at: 'phase' put: 'commentary'; at: 'text' put: '正在验证'; yourself); yourself)).
 (model answerText = '你好' and: [ model activityText includesSubstring: '正在验证' ])
  ifFalse: [ self error: 'Progress mixed into final answer' ].
 model acceptEnvelope: (envelope value: 'item/completed' value: (Dictionary new
  at: 'threadId' put: 'thread-test'; at: 'turnId' put: 'turn-test';
  at: 'item' put: (Dictionary new at: 'id' put: 'reason'; at: 'type' put: 'reasoning';
   at: 'summary' put: #('可展示的摘要'); at: 'content' put: #('PRIVATE_CONTENT_MARKER'); yourself); yourself)).
 ((model snapshot printString includesSubstring: 'PRIVATE_CONTENT_MARKER')
  or: [ model activityText includesSubstring: 'PRIVATE_CONTENT_MARKER' ])
   ifTrue: [ self error: 'Private reasoning content was copied' ].
 (model activityText includesSubstring: '可展示的摘要')
  ifFalse: [ self error: 'Display summary missing' ].
 model acceptEnvelope: (envelope value: 'item/completed' value: (Dictionary new
  at: 'threadId' put: 'thread-test'; at: 'turnId' put: 'turn-test';
  at: 'item' put: (Dictionary new at: 'id' put: 'tool'; at: 'type' put: 'dynamicToolCall';
   at: 'tool' put: 'runtime_eval'; at: 'status' put: 'completed'; at: 'success' put: false;
   at: 'arguments' put: (Dictionary new at: 'token' put: 'CREDENTIAL_MARKER'; yourself);
   at: 'contentItems' put: { Dictionary new at: 'type' put: 'inputText'; at: 'text' put: 'tool failed'; yourself };
   at: 'durationMs' put: 12; yourself); yourself)).
 ((model activityText includesSubstring: '失败') and: [
  (model activityText includesSubstring: 'tool failed') and: [
   (model snapshot printString includesSubstring: 'CREDENTIAL_MARKER') not ] ])
    ifFalse: [ self error: 'Tool status, result or structured masking failed' ].
 delta := delta deepCopy.
 (delta at: 'message' ) at: 'params' put: (Dictionary new
  at: 'threadId' put: 'another-thread'; at: 'turnId' put: 'turn-test';
  at: 'itemId' put: 'answer'; at: 'delta' put: 'WRONG_THREAD'; yourself).
 model acceptEnvelope: delta.
 model answerText = '你好' ifFalse: [ self error: 'Foreign thread mixed into answer' ].
 (delta at: 'message' at: 'params') at: 'threadId' put: 'thread-test'; at: 'turnId' put: 'another-turn'.
 model acceptEnvelope: delta.
 model answerText = '你好' ifFalse: [ self error: 'Foreign turn mixed into answer' ].
 (model instVarNamed: 'readErrors') = 0 ifFalse: [ self error: 'Unexpected parse errors' ].
 report at: 'ok' put: true; at: 'checks' put: #('partial UTF8 line buffered'
  'Chinese deltas render correctly' 'incremental reads do not replay'
  'completed answer replaces partial text' 'progress separated from answer'
  'reasoning content excluded' 'optional summary supported'
  'tool failure/result/timing projected' 'structured credentials masked'
  'foreign thread and turn ignored')
] on: Error do: [ :error | report at: 'ok' put: false; at: 'error' put: error messageText ].
report at: 'completedAt' put: DateAndTime now asString.
(ExperimentRoot / 'tests' / 'results' / 'conversation-stream-tests.json')
 binaryWriteStreamDo: [ :out | | resultBytes | resultBytes := (STONJSON toString: report) utf8Encoded. out nextPutAll: resultBytes; truncate: resultBytes size ].
report
