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
 ^ #(''agentMessage'' ''reasoning'' ''contextCompaction'' ''plan'' ''dynamicToolCall'' ''mcpToolCall'' ''commandExecution'' ''fileChange'' ''webSearch'')'.
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
 (type = ''loomActivity'' and: [ row includesKey: ''executionId'' ]) ifTrue: [ ^ false ].
type = ''agentMessage'' ifTrue: [
 ^ (row at: ''phase'' ifAbsent: [ nil ]) caseOf: {
  [ ''commentary'' ] -> [ true ].
  [ ''final_answer'' ] -> [ (row at: ''text'') isNotEmpty ] }
  otherwise: [ false ] ].
type = ''plan'' ifTrue: [ ^ (row at: ''text'') isNotEmpty ].
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
registry compile: 'recordBusinessEvent: fields call: callId
 | row |
 row := fields copy at: ''type'' put: ''loomActivity''; at: ''status'' put: ''completed'';
  at: ''text'' put: ''''; at: ''at'' put: self now; yourself.
 self database: [ :db | db transaction: [
  self putActivity: row call: callId item: (''business-'', UUID new asString) on: db.
  self projectExecutionEvent: row call: callId on: db ] ]'.
registry compile: 'executionOwner: executionId on: db
 ^ self record: ''SELECT json_object(''''call'''',call_id,''''item'''',item_id) FROM loom_activities
  WHERE json_extract(data,''''$.execution.id'''')=? LIMIT 1'' values: {executionId} on: db'.
registry compile: 'executionSession: client call: call on: db
 | key |
 key := client ifNil: [ self one: ''SELECT json_extract(request_json,''''$.clientKey'''') FROM calls WHERE request_id=?'' values: {call} on: db ].
 ^ (self one: ''SELECT id FROM loom_sessions WHERE client_key=?'' values: {key} on: db)
  ifNil: [ key ifNil: [ ''会话未记录'' ] ]'.
registry compile: 'projectExecutionEvent: event call: call on: db
 | id owner phase origin other from to |
 id := event at: ''executionId''. phase := event at: ''phase''.
 owner := self executionOwner: id on: db.
 owner ifNil: [ | tool item existing |
  tool := event at: ''toolCallId'' ifAbsent: [ nil ].
  item := tool ifNil: [ ''execution-'', id ].
  existing := self one: ''SELECT json_extract(data,''''$.execution.id'''') FROM loom_activities WHERE call_id=? AND item_id=?'' values: {call. item} on: db.
  (existing notNil and: [ existing ~= id ]) ifTrue: [ item := ''execution-'', id ].
  owner := Dictionary new at: ''call'' put: call; at: ''item'' put: item; yourself ].
 origin := event at: ''originExecutionId'' ifAbsent: [ nil ].
 origin ifNotNil: [
  (origin ~= id) ifTrue: [ other := self executionOwner: origin on: db ].
  to := self executionSession: (event at: ''clientKey'' ifAbsent: [ nil ]) call: call on: db.
  from := origin = id ifTrue: [ to ] ifFalse: [
   self executionSession: (event at: ''originClientKey'' ifAbsent: [ nil ])
    call: (other ifNotNil: [ other at: ''call'' ]) on: db ] ].
 self updateExecution: id owner: owner event: event from: from to: to on: db.
 other ifNotNil: [ self updateExecution: origin owner: other event: event from: from to: to on: db ]'.
registry compile: 'updateExecution: id owner: owner event: event from: from to: to on: db
 | row run phase at call item code |
 call := owner at: ''call''. item := owner at: ''item''. at := event at: ''at''. phase := event at: ''phase''.
 row := self entryFor: item call: call type: ''dynamicToolCall'' at: at on: db.
 row at: ''tool'' ifAbsentPut: [ ''runtime_eval'' ].
 run := row at: ''execution'' ifAbsentPut: [
  code := row at: ''arguments'' ifAbsent: [ nil ].
  code isDictionary ifTrue: [ code := code at: ''code'' ifAbsent: [ nil ] ].
  Dictionary new at: ''id'' put: id; at: ''startedAt'' put: at;
   at: ''session'' put: (self executionSession: (event at: ''clientKey'' ifAbsent: [ nil ]) call: call on: db);
   at: ''action'' put: (LMExecutionActivity actionFor: code); yourself ].
 (from notNil and: [ run includesKey: ''endedAt'' ]) ifTrue: [ ^ self ].
 (event at: ''executionId'') = id ifTrue: [
  event at: ''parentExecutionId'' ifPresent: [ :parent | run at: ''parentExecutionId'' put: parent ] ].
 run at: ''phase'' put: phase.
 phase = ''started'' ifTrue: [ run at: ''summary'' put: (''由 '', (run at: ''session''), '' 发起''); at: ''status'' put: ''inProgress'' ].
 from ifNotNil: [ LMExecutionActivity updateQuestionIn: run event: event from: from to: to ].
 (#(''done'' ''failed'' ''cancelled'') includes: phase) ifTrue: [
  self finishExecution: run event: event owner: owner tool: row on: db ].
 run at: ''title'' put: (LMExecutionActivity titleFor: run).
 self putActivity: row call: call item: item on: db'.
registry compile: 'finishExecution: run event: event owner: owner tool: row on: db
 | phase ended ms result value pending args |
 phase := event at: ''phase''. ended := event at: ''at''.
 ms := ((DateAndTime fromString: ended) - (DateAndTime fromString: (run at: ''startedAt''))) asMilliSeconds max: 0.
 run at: ''endedAt'' put: ended; at: ''durationMs'' put: ms;
  at: ''status'' put: (phase = ''done'' ifTrue: [ ''completed'' ] ifFalse: [ phase = ''failed'' ifTrue: [ ''failed'' ] ifFalse: [ ''interrupted'' ] ]).
 #(''checkpointId'' ''checkpointAt'') do: [ :key | event at: key ifPresent: [ :v | run at: key put: v ] ].
 value := event at: ''outcome'' ifAbsent: [ nil ].
 value ifNil: [
  result := self record: ''SELECT json_extract(data,''''$.result'''') FROM loom_activities WHERE call_id=? AND item_id=?''
    values: {owner at: ''call''. event at: ''toolCallId'' ifAbsent: [ nil ]} on: db.
  (result isDictionary and: [ (result includesKey: ''executionId'') not ]) ifTrue: [ result := result at: ''value'' ifAbsent: [ nil ] ].
  (result isDictionary and: [ (result at: ''executionId'' ifAbsent: [ nil ]) = (run at: ''id'') ]) ifTrue: [
   result at: ''value'' ifPresent: [ :v | value := LMExecutionActivity preview: v.
    args := row at: ''arguments'' ifAbsent: [ nil ].
    ((args isDictionary and: [ (args at: ''code'' ifAbsent: [ '''' ]) trimBoth = ''LMExecution checkpoint'' ]) and: [
     v isString and: [ [ (UUID fromString: v) asString = v ] on: Error do: [ :e | false ] ] ])
     ifTrue: [ run at: ''checkpointId'' put: v ] ].
   result at: ''error'' ifPresent: [ :v | value := LMExecutionActivity preview: v ].
   result at: ''valueClass'' ifPresent: [ :v | value := v, '' 对象'' ] ] ].
 pending := (run at: ''questions'' ifAbsent: [ #() ]) detect: [ :q | (q includesKey: ''answeredAt'') not ] ifNone: [ nil ].
 run at: ''summary'' put: (phase caseOf: {
  [ ''done'' ] -> [ value ifNil: [ ''执行完成，未记录返回值'' ] ifNotNil: [ ''结果　'', value ] ].
  [ ''failed'' ] -> [ value ifNil: [ ''执行失败，未记录错误信息'' ] ifNotNil: [ ''错误　'', value ] ].
  [ ''cancelled'' ] -> [ pending ifNil: [ ''轮次结束时，此操作尚未完成'' ]
   ifNotNil: [ ''取消时仍在等待 '', (pending at: ''to''), '' 答复 '', (pending at: ''selector'') ] ] })'.
registry compile: 'upgradeExecutionActivitiesOn: db
 | entries |
 db execute: ''CREATE INDEX IF NOT EXISTS loom_activity_execution ON loom_activities(json_extract(data,''''$.execution.id''''))
  WHERE json_extract(data,''''$.execution.id'''') IS NOT NULL''.
 revision := revision max: (db execute: ''SELECT COALESCE(MAX(change_revision),0) FROM loom_activities'') first asInteger.
 entries := db execute: ''SELECT json_object(''''call'''',call_id,''''item'''',item_id,''''event'''',json(data)) FROM loom_activities
  WHERE visible=1 AND json_extract(data,''''$.type'''')=''''loomActivity'''' AND json_extract(data,''''$.executionId'''') IS NOT NULL ORDER BY seq''.
 entries do: [ :line | | entry event |
  entry := STONJSON fromString: line. event := entry at: ''event''.
  self putActivity: event call: (entry at: ''call'') item: (entry at: ''item'') on: db.
  self projectExecutionEvent: event call: (entry at: ''call'') on: db ].
 (db execute: ''SELECT json_object(''''call'''',a.call_id,''''item'''',a.item_id,''''row'''',json(a.data)) FROM loom_activities a
  JOIN calls c ON c.request_id=a.call_id WHERE c.state<>''''started'''' AND json_extract(a.data,''''$.execution.status'''') IN (''''inProgress'''',''''pending'''')'') do: [ :line |
   | entry row |
   entry := STONJSON fromString: line. row := entry at: ''row''.
   self markUnfinishedExecution: (row at: ''execution'').
   self putActivity: row call: (entry at: ''call'') item: (entry at: ''item'') on: db ]'.
registry compile: 'markUnfinishedExecution: run
 run at: ''summary'' put: (''未记录结束结果。最后记录：'', (run at: ''summary''));
  at: ''phase'' put: ''unknown''; at: ''status'' put: ''interrupted''.
 run at: ''title'' put: (LMExecutionActivity titleFor: run)'.
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
 :line | | item data running |
 item := STONJSON fromString: line.
 data := STONJSON fromString: (item at: ''data'').
 running := #(''inProgress'' ''pending'' ''进行中'') includes: (data at: ''status'').
 running ifTrue: [ data at: ''status'' put: ''interrupted'' ].
 data at: ''execution'' ifPresent: [ :run | (#(''inProgress'' ''pending'') includes: (run at: ''status'')) ifTrue: [
  self markUnfinishedExecution: run. running := true ] ].
 running ifTrue: [ self putActivity: data call: call item: (item at: ''id'') on: db ] ]'.
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
  ''''executionPhase'''',json_extract(a.data,''''$.execution.phase''''),
  ''''status'''',coalesce(json_extract(a.data,''''$.execution.status''''),json_extract(a.data,''''$.status'''')),
  ''''at'''',json_extract(a.data,''''$.at''''),
  ''''title'''',substr(coalesce(json_extract(a.data,''''$.execution.title''''),json_extract(a.data,''''$.title'''')),1,160),
  ''''tool'''',COALESCE(json_extract(a.data,''''$.tool''''),''''''''),
  ''''durationMs'''',coalesce(json_extract(a.data,''''$.execution.durationMs''''),json_extract(a.data,''''$.durationMs'''')),
  ''''success'''',CASE WHEN json_extract(a.data,''''$.execution.id'''') IS NULL THEN json_extract(a.data,''''$.success'''')
   ELSE CASE json_extract(a.data,''''$.execution.phase'''') WHEN ''''done'''' THEN 1 WHEN ''''failed'''' THEN 0 END END,
  ''''text'''',substr(COALESCE(json_extract(a.data,''''$.execution.summary''''),json_extract(a.data,''''$.text''''),''''''''),1,360),
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
