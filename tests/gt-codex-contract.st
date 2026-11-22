"Native session registry, activity, and settings checks. The test root is disposable."
| base registry request receipt binding file cache settings verify page older protected requestId data roster log |
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
log := base / 'logs' / 'codex-events' / (requestId, '.events.jsonl').
log parent ensureCreateDirectory.
data := '{"direction":"server","at":"2026-11-01T10:00:30Z","message":{"method":"item/completed","params":{"item":{"id":"legacy","type":"agentMessage","phase":"commentary","text":"Imported history"}}}}'.
log writeStreamDo: [ :stream | stream nextPutAll: data; lf ].
registry migrateActivityLogs: base / 'logs' codexHome: base / 'codex'.
registry migrateActivityLogs: base / 'logs' codexHome: base / 'codex'.
page := registry activityPageFrom: nil limit: 1 previous: 1 focus: nil session: 'Fixture-1' managedOnly: true.
verify value: (((page at: 'items') first at: 'text') = 'Imported history' and: [ page at: 'older' ])
 value: 'latest activity page retains older history'.
older := registry activityPageFrom: (page at: 'first') limit: 2 previous: 1 focus: nil session: 'Fixture-1' managedOnly: true.
verify value: ((older at: 'items') size = 2 and: [ (older at: 'older') not ])
 value: 'legacy activity imports once and paginates by session'.
request := Dictionary new at: 'id' put: UUID new asString; at: 'action' put: 'newConversation'; at: 'clientKey' put: 'default'; yourself.
receipt := registry reset: request.
verify value: (registry reset: request) = receipt value: 'replaying a completed reset is idempotent'.
binding := registry initializeDefault: 'old-thread'.
verify value: ((binding at: 'state') = 'unbound' and: [ (binding at: 'generation') = 1 ])
 value: 'reset survives old image state'.
file := base / 'codex.json'.
cache := base / 'models_cache.json'.
LMPlatformTools writeJSON: (STONJSON fromString: '{"model":"fixture","effort":"medium","fast":false}') to: file.
LMPlatformTools writeJSON: (STONJSON fromString: '{"models":[{"visibility":"list","slug":"fixture","display_name":"Fixture","supported_reasoning_levels":[{"effort":"medium"},{"effort":"high"}],"service_tiers":[{"id":"priority"}]}]}') to: cache.
settings := LMNativeCodexSettings new initializeAt: file cache: cache; yourself.
settings save: (STONJSON fromString: '{"model":"fixture","effort":"high","fast":true}').
verify value: ((settings turnParams at: 'effort') = 'high' and: [ (settings turnParams at: 'serviceTier') = 'priority' ])
 value: 'settings select the requested effort and tier'.
protected := base / 'missing-registry'.
LMPlatformTools writeJSON: (Dictionary new at: 'installationId' put: 'stale'; yourself) to: protected / 'registry.json'.
verify value: ([ LMNativeSessionRegistry new initializeAt: protected. false ] on: Error do: [ :error | true ])
 value: 'a missing known database cannot silently create sessions'.
'GT Codex contract passed'
