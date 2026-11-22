"Activity records and views use the existing session SQLite tables."
| registry |
registry := LMNativeSessionRegistry.
registry compile: 'activitySource
 ^ '' FROM loom_activities a
 LEFT JOIN calls c ON c.request_id=a.call_id
 LEFT JOIN loom_sessions s ON s.client_key=COALESCE(json_extract(c.request_json,''''$.clientKey''''),
 (SELECT e.client_key FROM events e WHERE e.event=''''explicit-new-conversation''''
  AND (e.request_id=a.call_id OR ''''legacy-switch-''''||e.id=a.call_id) ORDER BY e.id LIMIT 1),
 (SELECT e.client_key FROM events e WHERE e.event IN (''''initialize'''',''''bound'''')
  AND e.thread_id=json_extract(c.result_json,''''$.threadId'''') ORDER BY e.id LIMIT 1))'''.
registry compile: 'activityTypes
 ^ #(''agentMessage'' ''reasoning'' ''plan'' ''dynamicToolCall'' ''mcpToolCall'' ''commandExecution'' ''fileChange'' ''webSearch'')'.
registry compile: 'masked: value
 value isDictionary ifTrue: [
 | copy |
 copy := Dictionary new.
 value keysAndValuesDo: [ :key :entry |
  copy at: key put: ((#(''apikey'' ''api_key'' ''token'' ''access_token'' ''authorization'' ''password'' ''secret'') includes: key asLowercase)
   ifTrue: [ ''[已隐藏]'' ] ifFalse: [ self masked: entry ]) ].
 ^ copy ].
value isArray ifTrue: [ ^ value collect: [ :entry | self masked: entry ] ].
^ value'.
registry compile: 'visibleActivity: row
 | type |
type := row at: ''type''.
type = ''agentMessage'' ifTrue: [ ^ (row at: ''phase'' ifAbsent: [ nil ]) = ''commentary'' ].
(#(''reasoning'' ''plan'') includes: type) ifTrue: [ ^ (row at: ''text'') isNotEmpty ].
^ true'.
registry compile: 'entryFor: item call: call type: type at: at on: db
 ^ (self record: ''SELECT data FROM loom_activities WHERE call_id=? AND item_id=?'' values: {call. item} on: db)
 ifNil: [ Dictionary new at: ''type'' put: type; at: ''text'' put: ''''; at: ''status'' put: ''inProgress''; at: ''at'' put: at; yourself ]'.
registry compile: 'putActivity: row call: call item: item on: db
 db execute: ''INSERT INTO loom_activities(call_id,item_id,visible,data) VALUES (?,?,?,?) ON CONFLICT(call_id,item_id) DO UPDATE SET visible=excluded.visible,data=excluded.data''
 values: {call. item. (self visibleActivity: row) ifTrue: [ 1 ] ifFalse: [ 0 ]. STONJSON toString: row}.
revision := revision + 1'.
registry compile: 'recordActivity: call title: title on: db
 self putActivity: (Dictionary new at: ''type'' put: ''loomActivity''; at: ''title'' put: title;
 at: ''text'' put: ''''; at: ''status'' put: ''completed''; at: ''at'' put: self now; yourself)
 call: call item: ''summary'' on: db'.
registry compile: 'finishActivity: call ok: ok on: db
 ok ifFalse: [
 self interruptActivity: call on: db.
 (self one: ''SELECT 1 FROM loom_activities WHERE call_id=? AND item_id=''''summary'''''' values: {call} on: db)
  ifNil: [ self recordActivity: call title: ''Codex 调用未完成'' on: db ].
 ^ self ].
(self one: ''SELECT 1 FROM loom_activities WHERE call_id=? AND visible=1 LIMIT 1'' values: {call} on: db)
 ifNil: [ self recordActivity: call title: ''Codex 调用已完成'' on: db ]'.
registry compile: 'interruptActivity: call on: db
 (db execute: ''SELECT json_object(''''id'''',item_id,''''data'''',data) FROM loom_activities WHERE call_id=? ORDER BY seq'' values: {call}) do: [
 :line | | item data |
 item := STONJSON fromString: line.
 data := STONJSON fromString: (item at: ''data'').
 (#(''inProgress'' ''pending'' ''进行中'') includes: (data at: ''status'')) ifTrue: [
  self putActivity: (data at: ''status'' put: ''interrupted''; yourself) call: call item: (item at: ''id'') on: db ] ]'.
registry compile: 'recoverActivities
 self database: [ :db |
 (db execute: ''SELECT request_id FROM calls WHERE state=''''started'''''') do: [ :id | self finishActivity: id ok: false on: db ] ]'.
registry compile: 'acceptActivity: event call: call
 self database: [ :db | self acceptActivity: event call: call at: self now on: db ]'.
registry compile: 'acceptActivity: event call: call at: at on: db
 | method params id item type row text |
method := event at: ''method''.
params := event at: ''params'' ifAbsent: [ ^ self ].
method = ''turn/completed'' ifTrue: [
 ((params at: ''turn'') at: ''status'') = ''completed'' ifFalse: [ self interruptActivity: call on: db ].
 ^ self ].
method = ''item/tool/call'' ifTrue: [
 id := params at: ''callId'' ifAbsent: [ ^ self ].
 row := self entryFor: id call: call type: ''dynamicToolCall'' at: at on: db.
 row at: ''tool'' put: (params at: ''tool''); at: ''arguments'' put: (self masked: (params at: ''arguments'')).
 ^ self putActivity: row call: call item: id on: db ].
type := method = ''item/agentMessage/delta'' ifTrue: [ ''agentMessage'' ] ifFalse: [
 method = ''item/reasoning/summaryTextDelta'' ifTrue: [ ''reasoning'' ] ].
type ifNotNil: [
 id := params at: ''itemId'' ifAbsent: [ ^ self ].
 text := params at: ''delta'' ifAbsent: [ ^ self ].
 row := self entryFor: id call: call type: type at: at on: db.
 row at: ''text'' put: (row at: ''text''), text.
 ^ self putActivity: row call: call item: id on: db ].
(#(''item/started'' ''item/completed'') includes: method) ifFalse: [ ^ self ].
item := params at: ''item'' ifAbsent: [ ^ self ].
id := item at: ''id'' ifAbsent: [ ^ self ].
type := item at: ''type''.
(self activityTypes includes: type) ifFalse: [ ^ self ].
row := self entryFor: id call: call type: type at: at on: db.
row at: ''status'' put: (item at: ''status'' ifAbsent: [ method = ''item/completed'' ifTrue: [ ''completed'' ] ifFalse: [ ''inProgress'' ] ]).
type = ''agentMessage'' ifTrue: [
 item at: ''phase'' ifPresent: [ :phase | row at: ''phase'' put: phase ].
 text := item at: ''text'' ifAbsent: [ '''' ].
 (text isNotEmpty or: [ method = ''item/completed'' ]) ifTrue: [ row at: ''text'' put: text ] ].
type = ''reasoning'' ifTrue: [ item at: ''summary'' ifPresent: [ :summary |
 summary ifNotEmpty: [ row at: ''text'' put: (String lf join: summary) ] ] ].
type = ''plan'' ifTrue: [ item at: ''text'' ifPresent: [ :plan | row at: ''text'' put: plan ] ].
#(''tool'' ''server'' ''arguments'' ''command'' ''aggregatedOutput'' ''exitCode'' ''durationMs'' ''success'' ''error'' ''result'' ''contentItems'' ''changes'' ''action'')
 do: [ :key | item at: key ifPresent: [ :value | row at: key put: (self masked: value) ] ].
self putActivity: row call: call item: id on: db'.
registry compile: 'completeToolActivity: id call: call result: result
 self database: [ :db |
 | row |
 row := self entryFor: id call: call type: ''dynamicToolCall'' at: self now on: db.
 row at: ''status'' put: ''completed''; at: ''success'' put: (result at: ''ok'');
  at: ''result'' put: (self masked: result).
 self putActivity: row call: call item: id on: db ]'.
registry compile: 'activityPageFrom: first limit: limit previous: previous focus: focus session: session managedOnly: managed
 ^ self database: [ :db |
 | selection args start items answer older recent |
 selection := self activitySource, '' WHERE a.visible=1''.
 args := #().
 session ifNil: [ managed ifTrue: [ selection := selection, '' AND s.id IS NOT NULL'' ] ]
  ifNotNil: [ selection := selection, '' AND s.id=?''. args := {session} ].
 recent := ''SELECT min(seq) FROM (SELECT a.seq'', selection.
 start := first.
 start ifNil: [
  start := self one: recent, '' ORDER BY a.seq DESC LIMIT ?)'' values: args, {limit} on: db
 ] ifNotNil: [
  limit > previous ifTrue: [
   start := (self one: recent, '' AND a.seq < ? ORDER BY a.seq DESC LIMIT ?)''
    values: args, {start. limit - previous} on: db) ifNil: [ start ] ] ].
 items := (db execute: ''SELECT json_object(''''call'''',a.call_id,''''item'''',a.item_id,''''data'''',a.data,''''session'''',s.id)'',
  selection, '' AND a.seq >= ? ORDER BY a.seq'' values: args, {start ifNil: [0]}) collect: [ :line |
  | row data |
  row := STONJSON fromString: line.
  data := STONJSON fromString: (row at: ''data'').
  data at: ''id'' put: (row at: ''call''), ''/'', (row at: ''item''); at: ''sessionId'' put: (row at: ''session''); yourself ].
 older := start notNil and: [
  (self one: ''SELECT 1'', selection, '' AND a.seq < ? LIMIT 1'' values: args, {start} on: db) notNil ].
 answer := focus ifNil: [''''] ifNotNil: [
  | filter focusArgs |
  filter := ''SELECT a.data'', self activitySource, '' WHERE a.call_id=?''.
  focusArgs := {focus}.
  session ifNotNil: [ filter := filter, '' AND s.id=?''. focusArgs := {focus. session} ].
  String lf join: (((db execute: filter, '' ORDER BY a.seq'' values: focusArgs)
   collect: [ :line | STONJSON fromString: line ])
   select: [ :row | (row at: ''type'') = ''agentMessage'' and: [
    (row at: ''phase'' ifAbsent: [nil]) = ''final_answer'' and: [ (row at: ''text'') isNotEmpty ] ] ]
   thenCollect: [ :row | row at: ''text'' ]) ].
 Dictionary new at: ''first'' put: start; at: ''items'' put: items; at: ''older'' put: older; at: ''answer'' put: answer; yourself ]'.
registry compile: 'migrateActivityLogs: logs codexHome: home
 self database: [ :db | db transaction: [
 | calls switches cursor importBefore cache |
 (db execute: ''SELECT 1 FROM meta WHERE key=''''loom_activities_v1'''''') ifEmpty: [
  calls := (db execute: ''SELECT json_object(''''id'''',request_id,''''request'''',request_json,''''result'''',result_json) FROM calls ORDER BY rowid'')
   collect: [ :line | STONJSON fromString: line ].
  switches := (db execute: ''SELECT json_object(''''id'''',e.id,''''request'''',e.request_id,''''at'''',e.created_at) FROM events e
   WHERE e.event=''''explicit-new-conversation'''' AND NOT EXISTS (SELECT 1 FROM calls c WHERE c.request_id=e.request_id) ORDER BY e.created_at,e.id'')
   collect: [ :line | STONJSON fromString: line ].
  cursor := 1.
  importBefore := [ :time |
   [ cursor <= switches size and: [ ((switches at: cursor) at: ''at'') <= time ] ] whileTrue: [
    | event |
    event := switches at: cursor.
    self importSwitch: ((event at: ''request'') ifNil: [ ''legacy-switch-'', (event at: ''id'') asString ])
     at: (event at: ''at'') on: db.
    cursor := cursor + 1 ] ].
  cache := Dictionary new.
  calls do: [ :call |
   | id action reply at path threadId turnId |
   id := call at: ''id''.
   action := (STONJSON fromString: (call at: ''request'')) at: ''action''.
   reply := (call at: ''result'') ifNil: [ Dictionary new ] ifNotNil: [ :json | STONJSON fromString: json ].
   action = ''newConversation'' ifTrue: [
    at := self one: ''SELECT created_at FROM events WHERE request_id=? AND event=''''explicit-new-conversation'''' ORDER BY id LIMIT 1'' values: {id} on: db.
    at ifNotNil: [ importBefore value: at ].
    self importSwitch: id at: (at ifNil: [ self now ]) on: db ].
   action = ''ask'' ifTrue: [
    reply at: ''startedAt'' ifPresent: [ :time | time ifNotNil: [ importBefore value: time ] ].
    path := logs / ''codex-events'' / (id, ''.events.jsonl'').
    path exists ifTrue: [
     self parseLinesOf: path do: [ :event |
      (event at: ''direction'' ifAbsent: [ nil ]) = ''server'' ifTrue: [
       event at: ''message'' ifPresent: [ :message |
        self acceptActivity: message call: id at: (event at: ''at'' ifAbsent: [ self now ]) on: db ] ] ]
    ] ifFalse: [
     threadId := reply at: ''threadId'' ifAbsent: [ nil ].
     turnId := reply at: ''turnId'' ifAbsent: [ nil ].
     (threadId notNil and: [ turnId notNil ]) ifTrue: [
      (((cache at: threadId ifAbsentPut: [ self archivedItemsFor: threadId in: home ])
        at: turnId ifAbsent: [ #() ]) do: [ :record |
          self acceptActivity: record second call: id at: record first on: db ]) ] ].
    self finishActivity: id ok: (reply at: ''ok'' ifAbsent: [ false ]) on: db ] ].
  importBefore value: (String with: (Character value: 65535)).
  db execute: ''INSERT INTO meta VALUES (''''loom_activities_v1'''',?)'' values: {self now} ] ] ]'.
registry compile: 'importSwitch: id at: at on: db
 self putActivity: (Dictionary new at: ''type'' put: ''loomActivity''; at: ''title'' put: ''已切换 Codex 会话'';
 at: ''text'' put: ''''; at: ''status'' put: ''completed''; at: ''at'' put: at; yourself) call: id item: ''summary'' on: db'.
registry compile: 'parseLinesOf: file do: use
 file readStreamDo: [ :stream |
 [ stream atEnd ] whileFalse: [
  | line data |
  line := stream nextLine.
  data := [ STONJSON fromString: line ] on: Error do: [ :error | nil ].
  data ifNotNil: [ use value: data ] ] ]'.
registry compile: 'archivedItemsFor: thread in: home
 | turns found |
turns := Dictionary new.
#(''sessions'' ''archived_sessions'') do: [ :name |
 | folder |
 folder := home / name.
 (found isNil and: [ folder exists ]) ifTrue: [
  found := folder allChildren detect: [ :file |
   file isFile and: [ file basename endsWith: thread, ''.jsonl'' ] ] ifNone: [ nil ] ] ].
found ifNil: [ ^ turns ].
self parseLinesOf: found do: [ :envelope |
 | event original type item turn |
 (envelope at: ''type'' ifAbsent: [ nil ]) = ''event_msg'' ifTrue: [
  event := envelope at: ''payload''.
  (event at: ''type'' ifAbsent: [ nil ]) = ''item_completed'' ifTrue: [
   original := event at: ''item'' ifAbsent: [ nil ].
   turn := event at: ''turn_id'' ifAbsent: [ nil ].
   (original notNil and: [ turn notNil ]) ifTrue: [
    type := original at: ''type'' ifAbsent: [ '''' ].
    type ifNotEmpty: [ type := type first asLowercase asString, type allButFirst ].
    (self activityTypes includes: type) ifTrue: [
     item := original copy at: ''type'' put: type; yourself.
     original at: ''content_items'' ifPresent: [ :content | item at: ''contentItems'' put: content ].
     type = ''agentMessage'' ifTrue: [
      item at: ''text'' put: (String lf join: ((original at: ''content'' ifAbsent: [ #() ])
       collect: [ :part | part at: ''text'' ifAbsent: [ '''' ] ])) ].
     type = ''reasoning'' ifTrue: [
      item at: ''summary'' put: (original at: ''summary_text'' ifAbsent: [ #() ]) ].
     (turns at: turn ifAbsentPut: [ OrderedCollection new ]) add:
      {envelope at: ''timestamp'' ifAbsent: [ self now ].
       Dictionary new at: ''method'' put: ''item/completed'';
        at: ''params'' put: (Dictionary new at: ''item'' put: item; yourself); yourself} ] ] ] ] ].
^ turns'.
'GT Codex activity storage installed'
