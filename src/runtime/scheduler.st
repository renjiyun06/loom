"Schedule durable daily Loom jobs in a GT background process."
| scheduler |
scheduler := (Object << #LMScheduler
 slots: #(directory mutex handlers worker runner closed lastError);
 package: 'Loom-Application') install.
scheduler compile: 'initializeAt: aDirectory
 directory := aDirectory.
 mutex := Mutex new.
 handlers := Dictionary new.
 closed := false.
 directory ensureCreateDirectory.
 self database: [ :db |
  db execute: ''PRAGMA journal_mode=WAL''.
  db transaction: [
   db execute: ''CREATE TABLE IF NOT EXISTS scheduled_tasks(
    id TEXT PRIMARY KEY, handler TEXT NOT NULL,
    local_second INTEGER NOT NULL CHECK(local_second BETWEEN 0 AND 86399),
    utc_offset_minutes INTEGER NOT NULL CHECK(utc_offset_minutes BETWEEN -840 AND 840),
    enabled INTEGER NOT NULL CHECK(enabled IN (0,1)))''.
   db execute: ''CREATE TABLE IF NOT EXISTS scheduled_runs(
    id TEXT PRIMARY KEY, task_id TEXT NOT NULL REFERENCES scheduled_tasks(id), handler TEXT NOT NULL,
    scheduled_at INTEGER NOT NULL, triggered_at INTEGER NOT NULL, started_at INTEGER, finished_at INTEGER,
    status TEXT NOT NULL CHECK(status IN (''''queued'''',''''running'''',''''completed'''',''''failed'''',''''interrupted'''')),
    result_json TEXT, error_stage TEXT, error TEXT, UNIQUE(task_id,scheduled_at))''.
   db execute: ''CREATE INDEX IF NOT EXISTS pending_scheduled_runs
    ON scheduled_runs(scheduled_at, id) WHERE status=''''queued''''''.
   db execute: ''UPDATE scheduled_runs SET status=''''interrupted'''', finished_at=?, error_stage=''''restart'''',
    error=''''Loom stopped before the task outcome was recorded'''' WHERE status=''''running''''''
    values: { DateAndTime now asUnixTime } ] ]'.
scheduler compile: 'databaseFile ^ directory / ''schedules.sqlite'''.
scheduler compile: 'database: operation
 ^ mutex critical: [
  LMExecution nativeStateCritical: [ LMSqliteDatabase new during: operation on: self databaseFile ] ]'.
scheduler compile: 'registerHandler: name do: operation
 (name isString and: [ name trimBoth isNotEmpty ]) ifFalse: [ self error: ''Expected a handler name'' ].
 operation numArgs = 1 ifFalse: [ self error: ''A schedule handler must accept its run record'' ].
 handlers at: name asString put: operation'.
scheduler compile: 'configureDaily: id handler: name at: time utcOffsetMinutes: offset enabled: enabled
 ((id isString and: [ id trimBoth isNotEmpty ]) and: [
 (name isString and: [ name trimBoth isNotEmpty ]) and: [
 (time isKindOf: Time) and: [ (offset isInteger and: [ offset between: -840 and: 840 ]) and: [
 enabled == true or: [ enabled == false ] ] ] ] ]) ifFalse: [
  self error: ''Invalid daily task configuration'' ].
 self database: [ :db |
  db execute: ''INSERT INTO scheduled_tasks(id,handler,local_second,utc_offset_minutes,enabled)
   VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET handler=excluded.handler,
   local_second=excluded.local_second, utc_offset_minutes=excluded.utc_offset_minutes, enabled=excluded.enabled''
   values: { id. name. time asSeconds. offset. enabled ifTrue: [ 1 ] ifFalse: [ 0 ] } ].
 ^ id'.
scheduler compile: 'tasksOn: db
 ^ (db execute: ''SELECT json_object(''''id'''',id,''''handler'''',handler,
  ''''localSecond'''',local_second,''''utcOffsetMinutes'''',utc_offset_minutes,''''enabled'''',enabled)
  FROM scheduled_tasks ORDER BY id'') collect: [ :json | STONJSON fromString: json ]'.
scheduler compile: 'tasks
 ^ self database: [ :db | self tasksOn: db ]'.
scheduler compile: 'runQuery
 ^ ''SELECT json_object(''''id'''',id,''''taskId'''',task_id,''''handler'''',handler,
  ''''scheduledAt'''',scheduled_at,''''triggeredAt'''',triggered_at,
  ''''startedAt'''',started_at,''''finishedAt'''',finished_at,
  ''''status'''',status,''''result'''',json(result_json),''''errorStage'''',error_stage,''''error'''',error) FROM scheduled_runs'''.
scheduler compile: 'runsFor: taskId limit: limit
 ^ self database: [ :db |
  (db execute: self runQuery, '' WHERE task_id=? ORDER BY scheduled_at DESC LIMIT ?''
   values: { taskId. limit }) collect: [ :json | STONJSON fromString: json ] ]'.
scheduler compile: 'enqueueDueAt: now
 "Time arguments and durable timestamps are Unix seconds. Only the current local day is considered."
 ^ self database: [ :db |
  db transaction: [
   (self tasksOn: db) do: [ :task |
    (task at: ''enabled'') = 1 ifTrue: [
     | offset scheduled |
     offset := (task at: ''utcOffsetMinutes'') * 60.
     scheduled := (((now + offset) // 86400) * 86400) + (task at: ''localSecond'') - offset.
     scheduled <= now ifTrue: [
      db execute: ''INSERT INTO scheduled_runs(id,task_id,handler,scheduled_at,triggered_at,status)
       VALUES (?,?,?,?,?,''''queued'''') ON CONFLICT(task_id,scheduled_at) DO NOTHING''
       values: { UUID new asString. task at: ''id''. task at: ''handler''. scheduled. now } ] ] ] ] ]'.
scheduler compile: 'claimNextAt: now
 ^ self database: [ :db |
  db transaction: [
   (db execute: self runQuery, '' WHERE status=''''queued'''' AND scheduled_at<=? ORDER BY scheduled_at,id LIMIT 1''
    values: { now }) ifEmpty: [ nil ] ifNotEmpty: [ :rows |
     | run |
     run := STONJSON fromString: rows first.
     db execute: ''UPDATE scheduled_runs SET status=''''running'''', started_at=? WHERE id=?''
      values: { now. run at: ''id'' }.
     run at: ''startedAt'' put: now; at: ''status'' put: ''running''; yourself ] ] ]'.
scheduler compile: 'finish: run status: state result: json error: reason stage: stage
 self database: [ :db |
  db execute: ''UPDATE scheduled_runs SET status=?,finished_at=?,result_json=?,error=?,error_stage=?
   WHERE id=? AND status=''''running''''''
   values: { state. DateAndTime now asUnixTime. json. reason. stage. run at: ''id'' } ]'.
scheduler compile: 'execute: run
 | operation result json stage |
 stage := ''dispatch''.
 [
  operation := handlers at: (run at: ''handler'') ifAbsent: [
   self error: ''Missing schedule handler: '', (run at: ''handler'') ].
  stage := ''execute''.
  result := operation value: run copy.
  stage := ''result''.
  json := STONJSON toString: result
 ] on: Error do: [ :error |
  ^ self finish: run status: ''failed'' result: nil error: error messageText stage: stage ].
 self finish: run status: ''completed'' result: json error: nil stage: nil'.
scheduler compile: 'isRunning
 ^ worker notNil and: [ worker isTerminated not and: [ closed not ] ]'.
scheduler compile: 'lastError ^ lastError'.
scheduler compile: 'isClosing
 ^ closed or: [
  (Smalltalk globals at: #LoomNativeCodexHost ifAbsent: [ nil ])
   ifNil: [ false ] ifNotNil: #isStopping ]'.
scheduler compile: 'dispatchNextAt: now
 (self isClosing or: [ runner notNil and: [ runner isTerminated not ] ]) ifTrue: [ ^ self ].
 (self claimNextAt: now) ifNotNil: [ :run |
  runner := [
   [ self execute: run ] on: Error do: [ :error | lastError := error messageText ]
  ] fork.
  runner name: ''Loom scheduled task'' ]'.
scheduler compile: 'run
 [ self isClosing ] whileFalse: [
  [ | now |
   now := DateAndTime now asUnixTime.
   self enqueueDueAt: now.
   self dispatchNextAt: now
  ] on: Error do: [ :error | lastError := error messageText ].
  (Delay forSeconds: 5) wait ]'.
scheduler compile: 'start
 (worker notNil and: [ worker isTerminated not ]) ifTrue: [ ^ self ].
 closed := false.
 worker := [ self run ] fork.
 worker name: ''Loom scheduler''.
 ^ self'.
scheduler compile: 'close closed := true'.
scheduler compile: 'retire
 self close.
 worker ifNotNil: #terminate.
 runner ifNotNil: #terminate'.
scheduler
