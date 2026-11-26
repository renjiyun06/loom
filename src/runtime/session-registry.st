"Durable Loom sessions and calls, shared with earlier versions of the runtime."
| registry |
registry := (Object << #LMNativeSessionRegistry slots: #(#directory #mutex #revision); package: 'Loom-Codex') install.
registry compile: 'initializeAt: path
 | marker exists id data |
directory := path.
directory ensureCreateDirectory.
mutex := Mutex new.
revision := 0.
marker := directory / ''registry.json''.
exists := self databaseFile exists.
(marker exists and: [ exists not ]) ifTrue: [ self error: ''Session registry is missing; refusing to create replacement conversations'' ].
self database: [ :db |
 db execute: ''PRAGMA journal_mode=WAL''.
 db transaction: [ self upgrade: db create: exists not ].
 revision := (db execute: ''SELECT COALESCE(MAX(change_revision),0) FROM loom_activities'') first asInteger.
 id := (db execute: ''SELECT value FROM meta WHERE key=''''installation_id'''''') first.
 db execute: ''SELECT client_key FROM bindings LIMIT 1'' ].
marker exists ifTrue: [
 data := STONJSON fromString: marker contents.
 (data at: ''installationId'') = id ifFalse: [ self error: ''Session registry identity mismatch'' ]
] ifFalse: [
 LMPlatformTools writeJSON: (Dictionary new at: ''version'' put: 1; at: ''installationId'' put: id; yourself) to: marker ]'.
registry compile: 'databaseFile
 "For custom read-only activity queries. loom_activities.call_id joins calls.request_id. A recovery call keeps the first request id in request_json under originalRequestId. The activity payload is in loom_activities.data as JSON."
 ^ directory / ''sessions.sqlite'''.
registry compile: 'database: block
 ^ mutex critical: [
 LMExecution nativeStateCritical: [ LMSqliteDatabase new during: block on: self databaseFile ] ]'.
registry compile: 'upgrade: db create: create
 | version |
create ifTrue: [
 #(''CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)''
   ''CREATE TABLE bindings(client_key TEXT PRIMARY KEY,generation INTEGER NOT NULL,state TEXT NOT NULL CHECK(state IN (''''unbound'''',''''creating'''',''''bound'''')),thread_id TEXT,request_id TEXT,updated_at TEXT NOT NULL)''
   ''CREATE TABLE events(id INTEGER PRIMARY KEY,client_key TEXT NOT NULL,event TEXT NOT NULL,generation INTEGER NOT NULL,thread_id TEXT,request_id TEXT,created_at TEXT NOT NULL)''
   ''PRAGMA user_version=1'') do: [ :sql | db execute: sql ].
 db execute: ''INSERT INTO meta VALUES (?,?)'' values: {''installation_id''. UUID new asString} ].
version := (db execute: ''PRAGMA user_version'') first asNumber.
(#(1 2 3 4 5 6 7) includes: version) ifFalse: [ self error: ''Invalid session registry schema; recovery is required'' ].
version < 2 ifTrue: [
 db execute: ''CREATE TABLE calls(request_id TEXT PRIMARY KEY,state TEXT NOT NULL,request_json TEXT NOT NULL,result_json TEXT)'' ].
version < 3 ifTrue: [
 db execute: ''CREATE TABLE loom_sessions(id TEXT PRIMARY KEY,client_key TEXT NOT NULL UNIQUE REFERENCES bindings(client_key),created_at TEXT NOT NULL)''.
 db execute: ''INSERT INTO loom_sessions SELECT ''''conversation'''',client_key,COALESCE((SELECT created_at FROM events WHERE client_key=''''default'''' AND event=''''initialize'''' ORDER BY id LIMIT 1),updated_at) FROM bindings WHERE client_key=''''default'''''' ].
version < 4 ifTrue: [
 db execute: ''UPDATE loom_sessions SET id=''''main'''' WHERE id=''''conversation'''' AND client_key=''''default''''''.
 db execute: ''PRAGMA user_version=4'' ].
db execute: ''CREATE TABLE IF NOT EXISTS loom_activities(seq INTEGER PRIMARY KEY,call_id TEXT NOT NULL,item_id TEXT NOT NULL,visible INTEGER NOT NULL CHECK(visible IN (0,1)),data TEXT NOT NULL,UNIQUE(call_id,item_id))''.
db execute: ''CREATE INDEX IF NOT EXISTS loom_activity_visible ON loom_activities(seq) WHERE visible=1''.
version < 5 ifTrue: [
 db execute: ''ALTER TABLE loom_activities ADD COLUMN change_revision INTEGER NOT NULL DEFAULT 0''.
 db execute: ''CREATE INDEX loom_activity_revision ON loom_activities(change_revision)''.
 db execute: ''PRAGMA user_version=5'' ].
version < 6 ifTrue: [
 | next |
 next := (db execute: ''SELECT COALESCE(MAX(change_revision),0) FROM loom_activities'') first asInteger + 1.
 db execute: ''UPDATE loom_activities SET visible=1,change_revision=? WHERE visible=0
  AND json_extract(data,''''$.type'''')=''''agentMessage'''' AND json_extract(data,''''$.phase'''')=''''final_answer''''
  AND length(json_extract(data,''''$.text'''')) > 0'' values: { next }.
 db execute: ''PRAGMA user_version=6'' ].
version < 7 ifTrue: [
 | next |
 next := (db execute: ''SELECT COALESCE(MAX(change_revision),0) FROM loom_activities'') first asInteger + 1.
 db execute: ''UPDATE loom_activities SET visible=1,change_revision=? WHERE visible=0
  AND json_extract(data,''''$.type'''')=''''reasoning'''''' values: { next }.
 db execute: ''PRAGMA user_version=7'' ]'.
registry compile: 'upgradeActivityTracking
 self database: [ :db |
  db transaction: [ self upgrade: db create: false ].
  revision := revision max: (db execute: ''SELECT COALESCE(MAX(change_revision),0) FROM loom_activities'') first asInteger ]'.
registry compile: 'now
 ^ DateAndTime now asUTC asString'.
registry compile: 'revision
 ^ revision'.
registry compile: 'one: sql values: values on: db
 ^ (db execute: sql values: values) ifEmpty: [ nil ] ifNotEmpty: [ :rows | rows first ]'.
registry compile: 'record: sql values: args on: db
 ^ (self one: sql values: args on: db) ifNotNil: [ :json | STONJSON fromString: json ]'.
registry compile: 'validate: key max: maximum
 (key isString and: [ key isNotEmpty and: [ key size <= maximum and: [
 key allSatisfy: [ :c | ''abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-'' includes: c ] ] ] ])
 ifFalse: [ self error: ''Invalid conversation or session identifier'' ]'.
registry compile: 'validateSession: id
 self validate: id max: 96.
id first isAlphaNumeric ifFalse: [ self error: ''Invalid Loom session ID'' ]'.
registry compile: 'binding: key on: db
 | data |
self validate: key max: 128.
data := self record: ''SELECT json_object(''''clientKey'''',client_key,''''generation'''',generation,''''state'''',state,''''threadId'''',thread_id,''''requestId'''',request_id) FROM bindings WHERE client_key=?'' values: {key} on: db.
(data notNil and: [ (data at: ''state'') = ''bound'' and: [
 (data at: ''threadId'') isNil or: [ (data at: ''threadId'') isEmpty ] ] ])
 ifTrue: [ self error: ''Session binding is invalid; recovery is required'' ].
^ data'.
registry compile: 'addBinding: key thread: thread on: db
 db execute: ''INSERT INTO bindings VALUES (?,?,?,?,?,?)'' values:
 {key. 0. thread ifNil: [ ''unbound'' ] ifNotNil: [ ''bound'' ]. thread. nil. self now}.
self log: key event: ''initialize'' generation: 0 thread: thread request: nil on: db.
^ self binding: key on: db'.
registry compile: 'ensureClient: key on: db
 ^ (self binding: key on: db) ifNil: [
 key = ''default'' ifTrue: [ self error: ''Default conversation binding is missing'' ].
 self addBinding: key thread: nil on: db ]'.
registry compile: 'ensureClient: key
 ^ self database: [ :db | db transaction: [ self ensureClient: key on: db ] ]'.
registry compile: 'initializeDefault: legacy
 ^ self database: [ :db | db transaction: [
 (self binding: ''default'' on: db) ifNil: [
  (db execute: ''SELECT 1 FROM meta WHERE key=''''default_initialized'''''') ifNotEmpty: [
   self error: ''Default conversation binding disappeared; refusing replacement'' ].
  self addBinding: ''default'' thread: legacy on: db.
  db execute: ''INSERT INTO meta VALUES (''''default_initialized'''',''''1'''')''.
  db execute: ''INSERT INTO loom_sessions VALUES (?,?,?)'' values: {''main''. ''default''. self now}.
  self binding: ''default'' on: db ] ] ]'.
registry compile: 'log: key event: event generation: generation thread: threadId request: requestId on: db
 db execute: ''INSERT INTO events(client_key,event,generation,thread_id,request_id,created_at) VALUES (?,?,?,?,?,?)'' values:
 {key. event. generation. threadId. requestId. self now}'.
registry compile: 'sessionIdFor: key
 ^ self database: [ :db | self one: ''SELECT id FROM loom_sessions WHERE client_key=?'' values: {key} on: db ]'.
registry compile: 'session: id on: db
 | data binding threads |
self validateSession: id.
data := self record: ''SELECT json_object(''''id'''',id,''''clientKey'''',client_key,''''createdAt'''',created_at) FROM loom_sessions WHERE id=?'' values: {id} on: db.
data ifNil: [ ^ nil ].
binding := self binding: (data at: ''clientKey'') on: db.
binding keysAndValuesDo: [ :key :value | data at: key put: value ].
threads := (db execute: ''SELECT json_object(''''generation'''',generation,''''threadId'''',thread_id,''''startedAt'''',created_at) FROM events WHERE client_key=? AND event IN (''''bound'''',''''initialize'''') AND thread_id IS NOT NULL ORDER BY id''
 values: { data at: ''clientKey'' }) collect: [ :json |
 | entry |
 entry := STONJSON fromString: json.
 entry at: ''current'' put: ((entry at: ''generation'') = (data at: ''generation'') and: [ (entry at: ''threadId'') = (data at: ''threadId'') ]).
 entry ].
^ data at: ''threads'' put: threads; yourself'.
registry compile: 'session: id
 ^ self database: [ :db | self session: id on: db ]'.
registry compile: 'sessions
 ^ self database: [ :db |
 (db execute: ''SELECT id FROM loom_sessions ORDER BY (id=''''main'''') DESC, id'') collect: [ :id | self session: id on: db ] ]'.
registry compile: 'register: id
 ^ self database: [ :db | db transaction: [
 (self session: id on: db) ifNil: [ | key |
  id = ''main'' ifTrue: [ self error: ''Default conversation binding is missing'' ].
  key := ''loom.'', id.
  self ensureClient: key on: db.
  db execute: ''INSERT INTO loom_sessions VALUES (?,?,?)'' values: {id. key. self now}.
  self session: id on: db ] ] ]'.
registry compile: 'beginCreate: key request: id
 self database: [ :db | db transaction: [
 | binding |
 binding := self binding: key on: db.
 (binding notNil and: [ (binding at: ''state'') = ''unbound'' ])
  ifFalse: [ self error: ''A conversation already exists or creation is unresolved; refusing a new conversation'' ].
 db execute: ''UPDATE bindings SET state=''''creating'''',request_id=?,updated_at=? WHERE client_key=?'' values: {id. self now. key}.
 self log: key event: ''creation-started'' generation: (binding at: ''generation'') thread: nil request: id on: db ] ]'.
registry compile: 'bind: thread key: key request: id
 self database: [ :db | db transaction: [
 | binding |
 binding := self binding: key on: db.
 (binding notNil and: [
  (binding at: ''state'') = ''creating'' and: [ (binding at: ''requestId'') = id and: [ thread isString and: [ thread isNotEmpty ] ] ] ])
  ifFalse: [ self error: ''Unexpected conversation creation result'' ].
 db execute: ''UPDATE bindings SET state=''''bound'''',thread_id=?,updated_at=? WHERE client_key=?'' values: {thread. self now. key}.
 self log: key event: ''bound'' generation: (binding at: ''generation'') thread: thread request: id on: db ] ]'.
registry compile: 'callResult: id on: db
 | result info request binding |
info := self record: ''SELECT json_object(''''result'''',result_json,''''request'''',request_json) FROM calls WHERE request_id=?'' values: {id} on: db.
info ifNil: [ ^ nil ].
result := info at: ''result''.
result ifNotNil: [ ^ STONJSON fromString: result ].
request := STONJSON fromString: (info at: ''request'').
binding := self binding: (request at: ''clientKey'') on: db.
^ Dictionary new at: ''ok'' put: false; at: ''id'' put: id;
 at: ''threadId'' put: (binding ifNotNil: [ binding at: ''threadId'' ]);
 at: ''error'' put: ''The previous invocation was interrupted with an uncertain outcome; it was not sent again''; yourself'.
registry compile: 'callResult: id
 ^ self database: [ :db | self callResult: id on: db ]'.
registry compile: 'recoveredCalls
 ^ self database: [ :db |
 (db execute: ''SELECT request_id FROM calls'') collect: [ :id | id -> (self callResult: id on: db) ] ]'.
registry compile: 'beginCall: request
 self database: [ :db |
 db transaction: [
  db execute: ''INSERT INTO calls VALUES (?,''''started'''',?,NULL)'' values: {request at: ''id''. STONJSON toString: request}.
  request at: ''replacesRequestId'' ifPresent: [ :id | self prepareHandoffFrom: id for: request on: db ].
  request at: ''originalRequestId'' ifPresent: [ :original |
   self beginRecoveryActivity: original switching: (request includesKey: ''replacesRequestId'') on: db ] ] ]'.
registry compile: 'recordHandoffRequest: id turn: turn key: key thread: thread automatic: automatic
 self database: [ :db | db transaction: [
  | request binding row original |
  request := self record: ''SELECT request_json FROM calls WHERE request_id=? AND state=?''
   values: { id. ''started'' } on: db.
  binding := self binding: key on: db.
  (request notNil and: [ binding notNil and: [ (request at: ''clientKey'') = key and: [
   (binding at: ''threadId'') = thread ] ] ]) ifFalse: [ self error: ''当前调用或 Codex 会话已变更'' ].
  self log: key event: (automatic ifTrue: [ ''stall-handoff-automatic'' ] ifFalse: [ ''stall-handoff-requested'' ])
   generation: (binding at: ''generation'') thread: thread request: id on: db.
  original := request at: ''originalRequestId'' ifAbsent: [ id ].
  row := self recoveryRowFor: original on: db.
  row at: ''lastError'' put: ((automatic
   ifTrue: [ ''轮次静默且 Google 探测可达，已自动请求中断旧轮次 '' ]
   ifFalse: [ ''已请求中断旧轮次 '' ]), turn).
  self putRecoveryActivity: row title: ''等待旧轮次结束后接手'' status: ''recovering'' call: original on: db ] ]'.
registry compile: 'prepareHandoffFrom: previous for: request on: db
 | old receipt binding key original generation |
 old := self record: ''SELECT request_json FROM calls WHERE request_id=? AND state=?''
  values: { previous. ''completed'' } on: db.
 receipt := self callResult: previous on: db.
 key := request at: ''clientKey''.
 original := request at: ''originalRequestId''.
 binding := self binding: key on: db.
 (old notNil and: [ receipt notNil and: [ binding notNil and: [
  (receipt at: ''replaceCodexSession'' ifAbsent: [ false ]) and: [
  (old at: ''clientKey'') = key and: [
  (old at: ''originalRequestId'' ifAbsent: [ previous ]) = original and: [
  (binding at: ''state'') = ''bound'' and: [ (binding at: ''threadId'') = (receipt at: ''threadId'') ] ] ] ] ] ] ])
  ifFalse: [ self error: ''旧轮次未确认结束或 Codex 会话已变更，无法接手'' ].
 generation := (binding at: ''generation'') + 1.
 self log: key event: ''stall-handoff-retired'' generation: generation
  thread: (binding at: ''threadId'') request: (request at: ''id'') on: db.
 db execute: ''UPDATE bindings SET generation=?,state=''''unbound'''',thread_id=NULL,request_id=?,updated_at=? WHERE client_key=?''
  values: { generation. request at: ''id''. self now. key }'.
registry compile: 'completeCall: id result: result
 self database: [ :db | db transaction: [
 db execute: ''UPDATE calls SET state=''''completed'''',result_json=? WHERE request_id=?'' values: {STONJSON toString: result. id}.
 self finishCallActivity: id result: result on: db ] ]'.
registry compile: 'reset: request
 | key id |
key := request at: ''clientKey''.
id := request at: ''id''.
^ self database: [ :db | db transaction: [
 (self callResult: id on: db) ifNil: [
  | previous generation result |
  previous := self ensureClient: key on: db.
  generation := (previous at: ''generation'') + 1.
  self log: key event: ''explicit-new-conversation'' generation: generation thread: (previous at: ''threadId'') request: id on: db.
  db execute: ''UPDATE bindings SET generation=?,state=''''unbound'''',thread_id=NULL,request_id=?,updated_at=? WHERE client_key=?'' values: {generation. id. self now. key}.
  result := Dictionary new at: ''ok'' put: true; at: ''id'' put: id; at: ''text'' put: '''';
   at: ''threadId'' put: nil; at: ''generation'' put: generation; at: ''state'' put: ''unbound''; yourself.
  db execute: ''INSERT INTO calls VALUES (?,''''completed'''',?,?)'' values: {id. STONJSON toString: request. STONJSON toString: result}.
  self recordActivity: id title: ''已切换 Codex 会话'' on: db.
  result ] ] ]'.
'GT session registry installed'
