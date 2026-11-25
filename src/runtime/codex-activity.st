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
type = ''agentMessage'' ifTrue: [
 ^ (row at: ''phase'' ifAbsent: [ nil ]) caseOf: {
  [ ''commentary'' ] -> [ true ].
  [ ''final_answer'' ] -> [ (row at: ''text'') isNotEmpty ] }
  otherwise: [ false ] ].
(#(''reasoning'' ''plan'') includes: type) ifTrue: [ ^ (row at: ''text'') isNotEmpty ].
^ true'.
registry compile: 'entryFor: item call: call type: type at: at on: db
 ^ (self record: ''SELECT data FROM loom_activities WHERE call_id=? AND item_id=?'' values: {call. item} on: db)
 ifNil: [ Dictionary new at: ''type'' put: type; at: ''text'' put: ''''; at: ''status'' put: ''inProgress''; at: ''at'' put: at; yourself ]'.
registry compile: 'putActivity: row call: call item: item on: db
 | next |
 next := revision + 1.
 db execute: ''INSERT INTO loom_activities(call_id,item_id,visible,data,change_revision) VALUES (?,?,?,?,?)
  ON CONFLICT(call_id,item_id) DO UPDATE SET visible=excluded.visible,data=excluded.data,change_revision=excluded.change_revision''
 values: {call. item. (self visibleActivity: row) ifTrue: [ 1 ] ifFalse: [ 0 ]. STONJSON toString: row. next}.
 revision := next'.
registry compile: 'recordActivity: call title: title on: db
 self putActivity: (Dictionary new at: ''type'' put: ''loomActivity''; at: ''title'' put: title;
 at: ''text'' put: ''''; at: ''status'' put: ''completed''; at: ''at'' put: self now; yourself)
 call: call item: ''summary'' on: db'.
registry compile: 'recordTurnSilence: current stage: stage seconds: seconds
 self database: [ :db |
  self putActivity: (Dictionary new at: ''type'' put: ''loomActivity''; at: ''phase'' put: ''turnSilence'';
   at: ''title'' put: (''Codex 轮次已 '', (seconds // 60) asString, '' 分钟未收到新进展'');
   at: ''text'' put: (''最后观察到「'', stage, ''」''); at: ''status'' put: ''completed'';
   at: ''turnId'' put: (current at: ''turnId''); at: ''silentSeconds'' put: seconds;
   at: ''lastStage'' put: stage; at: ''at'' put: self now; yourself)
   call: (current at: ''requestId'') item: ''turn-silence-'', UUID new asString on: db ]'.
registry compile: 'recordNetworkWait: id during: current title: title status: status
 | call |
 call := current at: ''requestId''.
 self database: [ :db |
  | row |
  row := self entryFor: id call: call type: ''loomActivity'' at: self now on: db.
  row at: ''phase'' put: ''turnNetworkWait''; at: ''title'' put: title; at: ''status'' put: status;
   at: ''turnId'' put: (current at: ''turnId''); at: ''text'' put: (status = ''inProgress''
    ifTrue: [ ''每 15 秒重试，原 Codex 轮次继续运行'' ] ifFalse: [ ''本次网络等待已结束'' ]).
  self putActivity: row call: call item: id on: db ]'.
registry compile: 'finishActivity: call ok: ok on: db
 ok ifFalse: [
 self interruptActivity: call on: db.
 (self one: ''SELECT 1 FROM loom_activities WHERE call_id=? AND item_id=''''summary'''''' values: {call} on: db)
  ifNil: [ self recordActivity: call title: ''Codex 调用未完成'' on: db ].
 ^ self ].
(self one: ''SELECT 1 FROM loom_activities WHERE call_id=? AND visible=1 LIMIT 1'' values: {call} on: db)
 ifNil: [ self recordActivity: call title: ''Codex 调用已完成'' on: db ]'.
registry compile: 'recoveryRowFor: call on: db
 ^ self entryFor: ''summary'' call: call type: ''loomActivity'' at: self now on: db'.
registry compile: 'putRecoveryActivity: row title: title status: status call: call on: db
 | count message |
 count := row at: ''recoveryCount'' ifAbsent: [ 0 ].
 message := row at: ''lastError'' ifAbsent: [ '''' ].
 count > 0 ifTrue: [
  message := ''恢复 '', count asString, '' 次'', (message ifEmpty: [ '''' ] ifNotEmpty: [ '' · '', message ]) ].
 row at: ''phase'' put: ''callRecovery''; at: ''title'' put: title;
  at: ''status'' put: status; at: ''text'' put: message.
 self putActivity: row call: call item: ''summary'' on: db'.
registry compile: 'beginRecoveryActivity: call switching: switching on: db
 | row title |
 row := self recoveryRowFor: call on: db.
 row at: ''recoveryCount'' put: (row at: ''recoveryCount'' ifAbsent: [ 0 ]) + 1.
 title := switching ifTrue: [ ''正在新开 Codex 会话接手'' ] ifFalse: [ ''Codex 轮次失败，正在恢复'' ].
 self putRecoveryActivity: row title: title status: ''recovering'' call: call on: db'.
registry compile: 'finishCallActivity: call result: result on: db
 | request original recovering partial ok row |
 request := self record: ''SELECT request_json FROM calls WHERE request_id=?'' values: {call} on: db.
 original := request at: ''originalRequestId'' ifAbsent: [ call ].
 recovering := result at: ''needsRecovery'' ifAbsent: [ false ].
 partial := result at: ''partialFailure'' ifAbsent: [ false ].
 ok := result at: ''ok''.
 ((request at: ''objectInvocation'' ifAbsent: [ false ]) and: [
  ok not or: [ partial or: [ original ~= call or: [ result at: ''handoffRequested'' ifAbsent: [ false ] ] ] ] ])
  ifFalse: [ ^ self finishActivity: call ok: ok on: db ].
 ok ifFalse: [ self interruptActivity: call on: db ].
 row := self recoveryRowFor: original on: db.
 result at: ''error'' ifPresent: [ :reason | row at: ''lastError'' put: reason ].
 recovering ifTrue: [
  ^ self putRecoveryActivity: row title: ((result at: ''replaceCodexSession'' ifAbsent: [ false ])
  ifTrue: [ ''旧轮次已结束，等待新 Codex 会话接手'' ] ifFalse: [ ''Codex 轮次失败，等待恢复'' ])
  status: ''recovering'' call: original on: db ].
 partial ifTrue: [
  ^ self putRecoveryActivity: row title: ''Codex 轮次异常，结果已交回'' status: ''warning'' call: original on: db ].
 ok ifTrue: [
  ^ self putRecoveryActivity: row title: (original = call
   ifTrue: [ ''旧轮次已正常完成'' ] ifFalse: [ ''Codex 调用已恢复'' ]) status: ''completed'' call: original on: db ].
 self putRecoveryActivity: row title: ''Codex 调用未完成'' status: ''failed'' call: original on: db'.
registry compile: 'endRecoveryActivity: call because: reason on: db
 | row |
 row := self recoveryRowFor: call on: db.
 (row at: ''status'') = ''recovering'' ifTrue: [
  row at: ''lastError'' put: reason.
  self putRecoveryActivity: row title: ''Codex 调用未完成'' status: ''failed'' call: call on: db ]'.
registry compile: 'endRecoveryActivity: call because: reason
 self database: [ :db | self endRecoveryActivity: call because: reason on: db ]'.
registry compile: 'interruptActivity: call on: db
 (db execute: ''SELECT json_object(''''id'''',item_id,''''data'''',data) FROM loom_activities WHERE call_id=? ORDER BY seq'' values: {call}) do: [
 :line | | item data |
 item := STONJSON fromString: line.
 data := STONJSON fromString: (item at: ''data'').
 (#(''inProgress'' ''pending'' ''进行中'') includes: (data at: ''status'')) ifTrue: [
  self putActivity: (data at: ''status'' put: ''interrupted''; yourself) call: call item: (item at: ''id'') on: db ] ]'.
registry compile: 'recoverActivities
 self database: [ :db | db transaction: [
  (db execute: ''SELECT request_id FROM calls WHERE state=''''started'''''') do: [ :id |
   self finishCallActivity: id result: (self callResult: id on: db) on: db ].
  (db execute: ''SELECT call_id FROM loom_activities WHERE item_id=?
   AND json_extract(data,''''$.phase'''')=? AND json_extract(data,''''$.status'''')=?''
   values: { ''summary''. ''callRecovery''. ''recovering'' }) do: [ :id |
    self endRecoveryActivity: id because: ''Loom 已重启，之前的恢复未完成'' on: db ] ] ]'.
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
registry compile: 'activityScopeFor: session managedOnly: managed
 session ifNotNil: [ ^ { '' AND s.id=?''. { session } } ].
 ^ { managed ifTrue: [ '' AND s.id IS NOT NULL'' ] ifFalse: [ '''' ]. #() }'.
registry compile: 'activitySummariesWhere: where values: args on: db
 | sql |
 sql := ''SELECT json_object(
  ''''seq'''',a.seq,''''revision'''',a.change_revision,''''visible'''',a.visible,
  ''''id'''',a.call_id||''''/''''||a.item_id,''''sessionId'''',s.id,
  ''''type'''',json_extract(a.data,''''$.type''''),
  ''''phase'''',json_extract(a.data,''''$.phase''''),
  ''''status'''',json_extract(a.data,''''$.status''''),
  ''''at'''',json_extract(a.data,''''$.at''''),
  ''''title'''',substr(json_extract(a.data,''''$.title''''),1,160),
  ''''tool'''',COALESCE(json_extract(a.data,''''$.tool''''),''''''''),
  ''''durationMs'''',json_extract(a.data,''''$.durationMs''''),
  ''''success'''',json_extract(a.data,''''$.success''''),
  ''''text'''',COALESCE(substr(json_extract(a.data,''''$.text''''),1,360),''''''''),
  ''''codePreview'''',CASE WHEN json_extract(a.data,''''$.tool'''') IN (''''runtime_eval'''',''''pharo_eval'''')
   THEN substr(json_extract(a.data,''''$.arguments.code''''),1,320) END)''.
 ^ (db execute: sql, self activitySource, '' WHERE '', where values: args) collect: [ :line |
  | item |
  item := STONJSON fromString: line.
  (item at: ''success'') ifNotNil: [ :value | item at: ''success'' put: value ~= 0 ].
  item ]'.
registry compile: 'activitySummariesBefore: sequence limit: limit session: session managedOnly: managed
 | scope |
 scope := self activityScopeFor: session managedOnly: managed.
 ^ self activitySummariesBefore: sequence limit: limit where: ''a.visible=1'', scope first values: scope second'.
registry compile: 'activitySummariesForCall: requestId before: sequence limit: limit
 ^ self activitySummariesBefore: sequence limit: limit where: ''a.call_id=?'' values: { requestId }'.
registry compile: 'activitySummariesBefore: sequence limit: limit where: where values: values
 ^ self database: [ :db |
  | predicate args rows |
  predicate := where.
  args := values.
  sequence ifNotNil: [ predicate := predicate, '' AND a.seq < ?''. args := args, { sequence } ].
  rows := self activitySummariesWhere: predicate, '' ORDER BY a.seq DESC LIMIT ?''
   values: args, { limit + 1 } on: db.
  Dictionary new at: ''items'' put: (rows first: (rows size min: limit)) reversed;
   at: ''older'' put: rows size > limit; at: ''revision'' put: revision; yourself ]'.
registry compile: 'activityChangesAfter: previous from: first session: session managedOnly: managed
 previous = revision ifTrue: [ ^ { previous. #() } ].
 ^ self database: [ :db |
  | scope rows |
  scope := self activityScopeFor: session managedOnly: managed.
  rows := self activitySummariesWhere: ''a.change_revision > ? AND a.seq >= ?'', scope first, '' ORDER BY a.seq''
   values: { previous. first ifNil: [ 0 ] }, scope second on: db.
  { revision. rows } ]'.
registry compile: 'activityDetailAt: sequence
 ^ self database: [ :db |
  | entry row call |
  entry := self record: ''SELECT json_object(''''revision'''',change_revision,''''data'''',json(data),''''callId'''',call_id)
   FROM loom_activities WHERE seq=?'' values: { sequence } on: db.
  entry ifNotNil: [
   call := entry removeKey: ''callId''.
   row := entry at: ''data''.
   (row at: ''phase'' ifAbsent: [ nil ]) = ''callRecovery'' ifTrue: [
    row at: ''text'' put: (self recoveryDetailFor: call summary: (row at: ''text'') on: db) ] ].
  entry ]'.
registry compile: 'recoveryDetailFor: call summary: summary on: db
 | rows |
 rows := db execute: ''SELECT json_object(''''id'''',request_id,''''receipt'''',json(result_json)) FROM calls
  WHERE request_id=? OR json_extract(request_json,''''$.originalRequestId'''')=? ORDER BY rowid'' values: { call. call }.
 ^ String streamContents: [ :out |
  summary ifNotEmpty: [ out nextPutAll: summary; nextPut: Character lf; nextPut: Character lf ].
  rows do: [ :line |
   | attempt receipt |
   attempt := STONJSON fromString: line.
   out nextPutAll: ''请求 ID ''; nextPutAll: (attempt at: ''id''); nextPut: Character lf.
   receipt := attempt at: ''receipt''.
   receipt ifNil: [ out nextPutAll: ''尚无轮次回执'' ] ifNotNil: [
    out nextPutAll: (receipt at: ''turnStatus'' ifAbsent: [
     (receipt at: ''releasedAfterSilence'' ifAbsent: [ false ])
      ifTrue: [ ''交付时轮次尚未确认结束'' ]
      ifFalse: [ (receipt at: ''ok'') ifTrue: [ ''completed'' ] ifFalse: [ ''failed'' ] ] ]).
    (receipt at: ''threadId'' ifAbsent: [ nil ]) ifNotNil: [ :thread |
     out nextPut: Character lf; nextPutAll: ''Codex 会话 ''; nextPutAll: thread ].
    receipt at: ''error'' ifPresent: [ :reason | out nextPutAll: '' · ''; nextPutAll: reason ] ]
  ] separatedBy: [ out nextPut: Character lf; nextPut: Character lf ] ]'.
registry compile: 'activityAnswerFor: call
 ^ self database: [ :db |
  String lf join: (db execute: ''SELECT json_extract(data,''''$.text'''') FROM loom_activities WHERE call_id=?
   AND json_extract(data,''''$.type'''')=''''agentMessage'''' AND json_extract(data,''''$.phase'''')=''''final_answer''''
   AND length(json_extract(data,''''$.text'''')) > 0 ORDER BY seq''
   values: { call }) ]'.
#(activityPageFrom:limit:previous:focus:session:managedOnly: migrateActivityLogs:codexHome: importSwitch:at:on: parseLinesOf:do: archivedItemsFor:in:) do: [ :selector |
 (registry includesSelector: selector) ifTrue: [ registry removeSelector: selector ] ].
'GT Codex activity storage installed'
