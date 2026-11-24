"Codex thread context snapshots and account usage for the conversation toolbar."
| usage registry |
registry := LMNativeSessionRegistry.
registry compile: 'initializeUsageStorage
 self database: [ :db | db execute: ''CREATE TABLE IF NOT EXISTS loom_thread_usage (thread_id TEXT PRIMARY KEY, data TEXT NOT NULL)'' ]'.
registry compile: 'tokenUsageAt: thread
 ^ self database: [ :db | self record: ''SELECT data FROM loom_thread_usage WHERE thread_id=?'' values: { thread } on: db ]'.
registry compile: 'saveTokenUsage: snapshot for: thread
 self database: [ :db |
  db execute: ''INSERT INTO loom_thread_usage(thread_id,data) VALUES (?,?)
   ON CONFLICT(thread_id) DO UPDATE SET data=excluded.data'' values: { thread. STONJSON toString: snapshot } ]'.
usage := (Object << #LMCodexUsage slots: #(transport registry threads account nextRead generation); package: 'Loom-Codex') install.
usage compile: 'initializeWith: connection registry: storage
 transport := connection. registry := storage.
 registry initializeUsageStorage.
 threads := Dictionary new.
 generation := 0.
 account := Dictionary new. nextRead := Dictionary new'.
usage compile: 'acceptTokenUsage: event
 | thread info last total window recent cumulative snapshot |
 thread := event at: ''threadId'' ifAbsent: [ nil ].
 info := event at: ''tokenUsage'' ifAbsent: [ ^ self ].
 (thread isString and: [ info isDictionary ]) ifFalse: [ ^ self ].
 last := info at: ''last'' ifAbsent: [ ^ self ].
 total := info at: ''total'' ifAbsent: [ ^ self ].
 window := info at: ''modelContextWindow'' ifAbsent: [ nil ].
 recent := last at: ''totalTokens'' ifAbsent: [ nil ].
 cumulative := total at: ''totalTokens'' ifAbsent: [ nil ].
 (recent isInteger and: [ cumulative isInteger and: [ recent >= 0 and: [ cumulative >= 0 ] ] ]) ifFalse: [ ^ self ].
 snapshot := Dictionary new at: ''recent'' put: recent; at: ''total'' put: cumulative;
  at: ''window'' put: ((window isInteger and: [ window > 0 ]) ifTrue: [ window ] ifFalse: [ nil ]); yourself.
 (threads at: thread ifAbsent: [ nil ]) = snapshot ifTrue: [ ^ self ].
 threads at: thread put: snapshot.
 registry saveTokenUsage: snapshot for: thread'.
usage compile: 'threadSnapshot: thread
 ^ thread ifNotNil: [ threads at: thread ifAbsentPut: [ registry tokenUsageAt: thread ] ]'.
usage compile: 'resetAccount
 generation := generation + 1.
 account := Dictionary new. nextRead := Dictionary new'.
usage compile: 'refreshRates
 self refresh: ''account/rateLimits/read'' every: 60'.
usage compile: 'refreshDaily
 self refresh: ''account/usage/read'' every: 300'.
usage compile: 'refresh: method every: seconds
 | now observed |
 now := DateAndTime now.
 (now < (nextRead at: method ifAbsent: [ now ])) ifTrue: [ ^ self ].
 nextRead at: method put: now + seconds seconds.
 observed := generation.
 [ | result |
  result := [ transport rpc: method params: nil timeout: 10 ] on: Error do: [ :error | nil ].
  observed = generation ifTrue: [
   result ifNil: [
    nextRead at: method put: DateAndTime now + 30 seconds.
    (account includesKey: method) ifFalse: [ account at: method put: nil ]
   ] ifNotNil: [ account at: method put: result ] ] ] fork'.
usage compile: 'meteredLimits: rates
 | buckets |
 rates ifNil: [ ^ Dictionary new ].
 buckets := rates at: ''rateLimitsByLimitId'' ifAbsent: [ nil ].
 ^ (buckets ifNotNil: [ buckets at: ''codex'' ifAbsent: [ nil ] ])
  ifNil: [ rates at: ''rateLimits'' ifAbsent: [ Dictionary new ] ]'.
usage compile: 'recentDays: daily
 | entries minimum |
 daily ifNil: [ ^ #() ].
 entries := daily at: ''dailyUsageBuckets'' ifAbsent: [ nil ].
 entries ifNil: [ ^ #() ].
 minimum := (DateAndTime now asUTC - 6 days) asDate yyyymmdd.
 ^ ((entries select: [ :entry | (entry at: ''startDate'') >= minimum ])
  sorted: [ :a :b | (a at: ''startDate'') < (b at: ''startDate'') ]) asArray'.
usage compile: 'snapshotFor: thread
 | current rates limits windows daily |
 self refreshRates.
 current := self threadSnapshot: thread.
 rates := account at: ''account/rateLimits/read'' ifAbsent: [ nil ].
 limits := self meteredLimits: rates.
 windows := (#(''primary'' ''secondary'') collect: [ :field | limits at: field ifAbsent: [ nil ] ]) reject: #isNil.
 daily := account at: ''account/usage/read'' ifAbsent: [ nil ].
 ^ Dictionary new at: ''context'' put: current;
  at: ''weekly'' put: (windows detect: [ :each | (each at: ''windowDurationMins'' ifAbsent: [ nil ]) = 10080 ] ifNone: [ nil ]);
  at: ''windows'' put: windows; at: ''credits'' put: (limits at: ''credits'' ifAbsent: [ nil ]);
  at: ''daily'' put: (self recentDays: daily);
  at: ''dailyLoaded'' put: (account includesKey: ''account/usage/read''); yourself'.
usage
