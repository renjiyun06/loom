"Native session registry, activity, and settings checks. The test root is disposable."
| base registry request receipt binding file settings verify page older protected requestId data roster
  reader previous change sequence detail savedText progress restored answer |
base := ExperimentRoot / 'codex-contract'.
verify := [ :condition :message | condition ifFalse: [ self error: message ] ].
registry := LMNativeSessionRegistry new initializeAt: base / 'registry'; yourself.
registry initializeDefault: 'original-thread'.
verify value: ((registry initializeDefault: 'stale-image-cache') at: 'threadId') = 'original-thread'
 value: 'the saved image cannot replace a durable binding'.
roster := registry register: 'Fixture-1'.
verify value: (roster at: 'state') = 'unbound' value: 'a named session starts unbound'.
requestId := UUID new asString.
registry beginCreate: (roster at: 'clientKey') request: requestId.
verify value: ([ registry beginCreate: (roster at: 'clientKey') request: UUID new asString. false ]
 on: Error do: [ :error | true ]) value: 'pending creation cannot be sent twice'.
registry bind: 'fixture-thread' key: (roster at: 'clientKey') request: requestId.
verify value: ((registry session: 'Fixture-1') at: 'threadId') = 'fixture-thread' value: 'thread is committed before use'.
request := Dictionary new at: 'id' put: requestId; at: 'action' put: 'ask'; at: 'clientKey' put: (roster at: 'clientKey'); yourself.
registry beginCall: request.
verify value: (((registry callResult: requestId) at: 'error') includesSubstring: 'uncertain outcome')
 value: 'a started call is not replayed'.
receipt := Dictionary new at: 'ok' put: true; at: 'threadId' put: 'fixture-thread'; at: 'turnId' put: 'old-turn';
 at: 'startedAt' put: '2026-11-01T10:00:00Z'; at: 'completedAt' put: '2026-11-01T10:01:00Z'; yourself.
registry completeCall: requestId result: receipt.
verify value: (registry callResult: requestId) = receipt value: 'completed receipt is durable'.
data := STONJSON fromString: '{"method":"item/completed","params":{"item":{"id":"progress","type":"agentMessage","phase":"commentary","text":"Live activity"}}}'.
registry acceptActivity: data call: requestId.
registry acceptActivity: data call: requestId.
reader := LMActivityReader new registry: registry; channel: 'overview'; yourself.
page := reader pageOf: 1 session: 'Fixture-1'.
verify value: (((page at: 'items') first at: 'text') = 'Live activity' and: [ page at: 'older' ])
 value: 'latest activity page retains older history'.
older := reader pageOf: 2 session: 'Fixture-1'.
verify value: ((older at: 'items') size = 2 and: [ (older at: 'older') not ])
 value: 'duplicate events update one activity and paginate by session'.
progress := (older at: 'items') last.
previous := registry revision.
data := STONJSON fromString: '{"method":"item/tool/call","params":{"callId":"tool-1","tool":"runtime_eval","arguments":{"code":"1+1"}}}'.
registry acceptActivity: data call: requestId.
page := reader pageOf: 2 session: 'Fixture-1'.
verify value: (((page at: 'items') at: 2) == progress and: [ (page at: 'items') size = 3 ])
 value: 'appending a tool reuses the earlier published entries'.
sequence := (page at: 'items') last at: 'seq'.
savedText := String new: 30000 withAll: $x.
registry completeToolActivity: 'tool-1' call: requestId
 result: (Dictionary new at: 'ok' put: true; at: 'value' put: savedText; yourself).
change := (registry activityChangesAfter: previous from: nil session: 'Fixture-1' managedOnly: true) second.
verify value: (change size = 1 and: [ (change first at: 'seq') = sequence
 and: [ (change first at: 'status') = 'completed' ] ])
 value: 'a tool completion replaces the pending update at the same sequence'.
verify value: ((change first keys includesAny: #('arguments' 'result' 'contentItems' 'aggregatedOutput')) not)
 value: 'the summary does not carry full tool data'.
detail := (registry activityDetailAt: sequence) at: 'data'.
verify value: ((detail at: 'result') at: 'value') = savedText value: 'selected detail includes the full saved result'.
older := reader pageOf: 2 session: 'Fixture-1'.
verify value: (((older at: 'items') at: 2) == progress and: [ ((older at: 'items') last at: 'status') = 'completed' ])
 value: 'an incremental update keeps the order and identity of unchanged entries'.
data := STONJSON fromString: '{"method":"item/started","params":{"item":{"id":"answer","type":"agentMessage","phase":"final_answer"}}}'.
registry acceptActivity: data call: requestId.
verify value: (reader pageOf: 2 session: 'Fixture-1') == older
 value: 'the final answer appears once it has text'.
data := STONJSON fromString: '{"method":"item/agentMessage/delta","params":{"itemId":"answer","delta":"原样流式正文"}}'.
registry acceptActivity: data call: requestId.
verify value: (reader streamedReplyFor: requestId) = '原样流式正文' value: 'final text is still available through the reply lookup'.
page := reader pageOf: 2 session: 'Fixture-1'.
answer := (page at: 'items') last.
verify value: ((answer at: 'text') = '原样流式正文' and: [ (answer at: 'phase') = 'final_answer' ])
 value: 'the final answer is visible while streaming'.
data := STONJSON fromString: '{"method":"item/completed","params":{"item":{"id":"answer","type":"agentMessage","phase":"final_answer","text":"完整最终回复"}}}'.
registry acceptActivity: data call: requestId.
page := reader pageOf: 2 session: 'Fixture-1'.
verify value: (((page at: 'items') size = 4) and: [
 ((page at: 'items') last at: 'seq') = (answer at: 'seq') and: [
 ((page at: 'items') last at: 'text') = '完整最终回复' ] ])
 value: 'completion updates the streaming activity in place'.
data := STONJSON fromString: '{"method":"item/completed","params":{"item":{"id":"progress","type":"agentMessage","phase":"final_answer","text":"reclassified"}}}'.
registry acceptActivity: data call: requestId.
page := reader pageOf: 2 session: 'Fixture-1'.
verify value: ((page at: 'items') anySatisfy: [ :entry |
 (entry at: 'seq') = (progress at: 'seq') and: [ (entry at: 'phase') = 'final_answer' ] ])
 value: 'an activity that becomes a final answer stays visible'.
registry database: [ :db |
 db execute: 'UPDATE loom_activities SET visible=0 WHERE seq=?' values: { answer at: 'seq' }.
 db execute: 'PRAGMA user_version=5' ].
previous := registry revision.
registry upgradeActivityTracking.
change := (registry activityChangesAfter: previous from: nil session: 'Fixture-1' managedOnly: true) second.
verify value: (change size = 1 and: [
 (change first at: 'seq') = (answer at: 'seq') and: [ (change first at: 'visible') = 1 ] ])
 value: 'an upgrade restores saved final answers at their original sequence'.
restored := LMActivityReader new.
restored instVarNamed: #registry put: registry.
restored instVarNamed: #published put: page.
restored instVarNamed: #selection put: 'Fixture-1'.
restored instVarNamed: #loadedLimit put: 2.
restored instVarNamed: #revision put: registry revision.
verify value: (((restored pageOf: 2 session: 'Fixture-1') at: 'items') isEmpty
 and: [ restored registry == LoomNativeCodexHost registry ])
 value: 'a restored reader discards pages cached under a previous registry'.
request := Dictionary new at: 'id' put: UUID new asString; at: 'action' put: 'newConversation'; at: 'clientKey' put: 'default'; yourself.
receipt := registry reset: request.
verify value: (registry reset: request) = receipt value: 'replaying a completed reset is idempotent'.
binding := registry initializeDefault: 'old-thread'.
verify value: ((binding at: 'state') = 'unbound' and: [ (binding at: 'generation') = 1 ])
 value: 'reset survives old image state'.
[ | usage reopened account snapshot |
 usage := LMCodexUsage new initializeWith: nil registry: registry; yourself.
 usage acceptTokenUsage: (STONJSON fromString:
  '{"threadId":"fixture-thread","tokenUsage":{"last":{"totalTokens":80},"total":{"totalTokens":900},"modelContextWindow":200}}').
 reopened := LMCodexUsage new initializeWith: nil registry: registry; yourself.
 verify value: ((reopened threadSnapshot: 'fixture-thread') = (usage threadSnapshot: 'fixture-thread'))
  value: 'the thread usage snapshot survives a transport restart'.
 account := usage instVarNamed: 'account'.
 account at: 'account/rateLimits/read' put: (STONJSON fromString:
  '{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":5,"windowDurationMins":10080},"secondary":null}}}').
 (usage instVarNamed: 'nextRead') at: 'account/rateLimits/read' put: DateAndTime now + 60 seconds.
 snapshot := usage snapshotFor: nil.
 verify value: ((snapshot at: 'context') isNil and: [ ((snapshot at: 'weekly') at: 'usedPercent') = 5 ])
  value: 'changing threads clears context usage while retaining the account quota'.
 usage resetAccount.
 verify value: (account ~~ (usage instVarNamed: 'account') and: [ (usage threadSnapshot: 'fixture-thread') notNil ])
  value: 'changing accounts clears quota without replacing thread usage' ] value.
file := base / 'codex.json'.
LMPlatformTools writeJSON: (STONJSON fromString: '{"model":"fixture","effort":"medium","fast":false}') to: file.
settings := LMNativeCodexSettings new initializeAt: file;
 models: (STONJSON fromString: '[{"model":"fixture","displayName":"Fixture","supportedReasoningEfforts":[{"reasoningEffort":"medium"},{"reasoningEffort":"high"}],"serviceTiers":[{"id":"priority"}]}]'); yourself.
settings save: (STONJSON fromString: '{"model":"fixture","effort":"high","fast":true}').
verify value: ((settings turnParams at: 'effort') = 'high' and: [ (settings turnParams at: 'serviceTier') = 'priority' ])
 value: 'settings select the requested effort and tier'.
protected := base / 'missing-registry'.
LMPlatformTools writeJSON: (Dictionary new at: 'installationId' put: 'stale'; yourself) to: protected / 'registry.json'.
verify value: ([ LMNativeSessionRegistry new initializeAt: protected. false ] on: Error do: [ :error | true ])
 value: 'a missing known database cannot silently create sessions'.
[ | primary retry partial abandoned activeRequest makeRequest failure summary running completed warning reopened rows |
 makeRequest := [ :id | Dictionary new at: 'id' put: id; at: 'clientKey' put: (roster at: 'clientKey');
  at: 'action' put: 'ask'; at: 'objectInvocation' put: true; yourself ].
 primary := UUID new asString.
 retry := UUID new asString.
 failure := Dictionary new at: 'ok' put: false; at: 'error' put: 'fixture failure';
  at: 'turnStatus' put: 'failed'; at: 'needsRecovery' put: true; yourself.
 registry beginCall: (makeRequest value: primary).
 registry completeCall: primary result: failure.
 summary := ((registry activitySummariesBefore: nil limit: 1 session: 'Fixture-1' managedOnly: true) at: 'items') first.
 verify value: (summary at: 'title') = 'Codex 轮次失败，等待恢复' value: 'failure appears before the next attempt starts'.
 registry beginCall: ((makeRequest value: retry) at: 'originalRequestId' put: primary; yourself).
 running := ((registry activityChangesAfter: (summary at: 'revision') from: nil session: 'Fixture-1' managedOnly: true) second) first.
 verify value: ((running at: 'title') = 'Codex 轮次失败，正在恢复' and: [
  (running at: 'seq') = (summary at: 'seq') and: [ (running at: 'text') beginsWith: '恢复 1 次' ] ])
  value: 'starting a retry updates one activity and its attempt count'.
 registry completeCall: retry result: (Dictionary new at: 'ok' put: true; at: 'turnStatus' put: 'completed'; yourself).
 completed := ((registry activityChangesAfter: (running at: 'revision') from: nil session: 'Fixture-1' managedOnly: true) second) first.
 verify value: ((completed at: 'title') = 'Codex 调用已恢复' and: [ (completed at: 'seq') = (summary at: 'seq') ])
  value: 'the original activity shows final recovery with stable identity'.
 partial := UUID new asString.
 registry beginCall: (makeRequest value: partial).
 registry completeCall: partial result: (failure copy at: 'ok' put: true; at: 'needsRecovery' put: false;
  at: 'partialFailure' put: true; yourself).
 warning := ((registry activitySummariesBefore: nil limit: 1 session: 'Fixture-1' managedOnly: true) at: 'items') first.
 verify value: ((warning at: 'title') = 'Codex 轮次异常，结果已交回' and: [
  (LMConversationActivityView new descriptor: warning; yourself) activityIconName = 'triangle-alert' ])
  value: 'a saved result with a failed turn has a warning activity'.
 abandoned := UUID new asString.
 activeRequest := UUID new asString.
 registry beginCall: (makeRequest value: abandoned).
 registry completeCall: abandoned result: failure.
 registry beginCall: ((makeRequest value: activeRequest) at: 'originalRequestId' put: abandoned; yourself).
 reopened := LMNativeSessionRegistry new initializeAt: base / 'registry'; yourself.
 reopened recoverActivities.
 rows := (reopened activitySummariesBefore: nil limit: 3 session: 'Fixture-1' managedOnly: true) at: 'items'.
 verify value: ((rows collect: [ :item | item at: 'status' ]) = #('completed' 'warning' 'failed'))
  value: 'reopening preserves completed alerts and settles the interrupted recovery'.
 detail := ((reopened activityDetailAt: (completed at: 'seq')) at: 'data') at: 'text'.
 verify value: ((detail includesSubstring: primary) and: [
  (detail includesSubstring: retry) and: [ detail includesSubstring: 'fixture failure' ] ])
  value: 'persisted details contain the linked request IDs and failure reason'
] value.
'GT Codex contract passed'
