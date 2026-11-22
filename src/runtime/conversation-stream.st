"Display-only event projection; no tool replay and no private reasoning content."
| cls |
cls := (Object << #LMConversationStream slots: #(#file #requestId #offset #pending #items #order #state #changed #readErrors #threadId #turnId #activityCache #answerCache #revision); package: 'Loom-Conversation') install.
cls compile: 'acceptEnvelope: envelope
 | message method params item id entry type phase |
 revision := (revision ifNil: [ 0 ]) + 1.
 activityCache := nil. answerCache := nil.
 (envelope at: ''direction'' ifAbsent: [ '''' ]) = ''server'' ifFalse: [ ^ self ].
 message := envelope at: ''message''.
 method := message at: ''method'' ifAbsent: [ '''' ].
 params := message at: ''params'' ifAbsent: [ Dictionary new ].
 (params includesKey: ''threadId'') ifTrue: [
  threadId ifNil: [ threadId := params at: ''threadId'' ].
  (params at: ''threadId'') = threadId ifFalse: [ ^ self ] ].
 (params includesKey: ''turnId'') ifTrue: [
  turnId ifNil: [ turnId := params at: ''turnId'' ].
  (params at: ''turnId'') = turnId ifFalse: [ ^ self ] ].
 method = ''turn/started'' ifTrue: [ state := ''正在处理''. changed := true. ^ self ].
 method = ''turn/completed'' ifTrue: [
  state := ((params at: ''turn'') at: ''status'') = ''completed'' ifTrue: [ ''已完成'' ] ifFalse: [ ''已中断或失败'' ].
  ((params at: ''turn'') at: ''status'') ~= ''completed'' ifTrue: [
   order do: [ :entryId | | entry |
    entry := items at: entryId.
    (#(''inProgress'' ''pending'' ''进行中'') includes: (entry at: ''status'' ifAbsent: [ '''' ]))
     ifTrue: [ entry at: ''status'' put: ''interrupted'' ] ] ].
  changed := true. ^ self ].
 method = ''item/tool/call'' ifTrue: [
  entry := self item: (params at: ''callId'') type: ''dynamicToolCall''.
  entry at: ''tool'' put: (params at: ''tool''); at: ''arguments'' put: (self safeValue: (params at: ''arguments''));
   at: ''at'' put: (envelope at: ''at'').
  changed := true. ^ self ].
 method = ''item/agentMessage/delta'' ifTrue: [
  entry := self item: (params at: ''itemId'') type: ''agentMessage''.
  entry at: ''text'' put: (entry at: ''text'') , (params at: ''delta'').
  changed := true. ^ self ].
 method = ''item/reasoning/summaryTextDelta'' ifTrue: [
  entry := self item: (params at: ''itemId'') type: ''reasoning''.
  entry at: ''text'' put: (entry at: ''text'') , (params at: ''delta'').
  changed := true. ^ self ].
 (#(''item/started'' ''item/completed'') includes: method) ifFalse: [ ^ self ].
 item := params at: ''item''.
 type := item at: ''type''.
 (#(''agentMessage'' ''reasoning'' ''dynamicToolCall'' ''mcpToolCall'' ''commandExecution'' ''webSearch'' ''fileChange'' ''plan'') includes: type)
  ifFalse: [ ^ self ].
 id := item at: ''id''. entry := self item: id type: type.
 entry at: ''at'' put: (envelope at: ''at'').
 entry at: ''status'' put: (item at: ''status'' ifAbsent: [
  method = ''item/completed'' ifTrue: [ ''已完成'' ] ifFalse: [ ''进行中'' ] ]).
 type = ''agentMessage'' ifTrue: [
  phase := item at: ''phase'' ifAbsent: [ nil ].
  phase ifNotNil: [ entry at: ''phase'' put: phase ].
  ((item at: ''text'' ifAbsent: [ '''' ]) notEmpty or: [ method = ''item/completed'' ])
   ifTrue: [ entry at: ''text'' put: (item at: ''text'' ifAbsent: [ '''' ]) ] ].
 type = ''reasoning'' ifTrue: [
  | summary |
  summary := item at: ''summary'' ifAbsent: [ #() ].
  summary ifNotEmpty: [ entry at: ''text'' put: (String streamContents: [ :s | summary do: [ :part | s nextPutAll: part; cr ] ]) ] ].
 type = ''plan'' ifTrue: [ entry at: ''text'' put: (item at: ''text'' ifAbsent: [ '''' ]) ].
 #(''tool'' ''server'' ''arguments'' ''command'' ''aggregatedOutput'' ''exitCode'' ''durationMs'' ''success'' ''error'' ''result'' ''contentItems'' ''changes'' ''action'')
  do: [ :key | item at: key ifPresent: [ :value | entry at: key put: (self safeValue: value) ] ].
 changed := true'.
cls compile: 'activityText
 activityCache ifNotNil: [ ^ activityCache ].
 ^ activityCache := String streamContents: [ :stream |
  stream nextPutAll: state; cr; cr.
  order do: [ :id | | entry type text |
   entry := items at: id. type := entry at: ''type''. text := entry at: ''text''.
   (type = ''agentMessage'' and: [ (entry at: ''phase'' ifAbsent: [ '''' ]) = ''commentary'' ]) ifTrue: [
    stream nextPutAll: ''进度说明''; cr; nextPutAll: text; cr; cr ].
   (type = ''reasoning'' and: [ text notEmpty ]) ifTrue: [
    stream nextPutAll: ''思考摘要''; cr; nextPutAll: text; cr; cr ].
   type = ''plan'' ifTrue: [ stream nextPutAll: ''计划''; cr; nextPutAll: text; cr; cr ].
   (#(''dynamicToolCall'' ''mcpToolCall'' ''commandExecution'' ''fileChange'' ''webSearch'') includes: type) ifTrue: [
    stream nextPutAll: (entry at: ''tool'' ifAbsent: [
     type = ''commandExecution'' ifTrue: [ ''执行命令'' ] ifFalse: [
      type = ''fileChange'' ifTrue: [ ''修改文件'' ] ifFalse: [ ''搜索'' ] ] ]);
     nextPutAll: '' · ''; nextPutAll: (self statusLabel: entry).
    entry at: ''durationMs'' ifPresent: [ :duration |
     duration ifNotNil: [ stream nextPutAll: '' · ''; print: duration; nextPutAll: '' ms'' ] ].
    stream cr.
    #(''arguments'' ''command'') do: [ :key | entry at: key ifPresent: [ :value |
     value ifNotNil: [ stream nextPutAll: ''参数：''; cr;
      nextPutAll: (self clip: (self displayValue: value) limit: 650); cr ] ] ].
    #(''aggregatedOutput'' ''contentItems'' ''result'' ''error'' ''changes'')
     do: [ :key | entry at: key ifPresent: [ :value |
      value ifNotNil: [ stream nextPutAll: ''结果：''; cr;
       nextPutAll: (self clip: (self displayValue: value) limit: 650); cr ] ] ].
    stream cr ] ].
  readErrors > 0 ifTrue: [ stream nextPutAll: ''有 ''; print: readErrors; nextPutAll: '' 条事件未能解析。''; cr ] ]'.
cls compile: 'answerText
 | first |
 answerCache ifNotNil: [ ^ answerCache ].
 first := true.
 ^ answerCache := String streamContents: [ :out |
  order do: [ :id | | entry text |
   entry := items at: id. text := entry at: ''text''.
   ((entry at: ''type'') = ''agentMessage'' and: [
    (entry at: ''phase'' ifAbsent: [ '''' ]) = ''final_answer'' and: [ text notEmpty ] ])
    ifTrue: [
     first ifFalse: [ out lf ].
     first := false. out nextPutAll: text ] ] ]'.
cls compile: 'clip: text limit: limit
 ^ text size > limit
  ifTrue: [ (text first: limit), String cr, ''…（更多内容见活动详情）'' ]
  ifFalse: [ text ]'.
cls compile: 'displayValue: value
 value isString ifTrue: [
  ((value beginsWith: ''{'') or: [ value beginsWith: ''['' ]) ifTrue: [
   [ ^ self displayValue: (self safeValue: (STONJSON fromString: value)) ] on: Error do: [ :error | ] ].
  ^ value ].
 value isDictionary ifTrue: [
  (value includesKey: ''code'') ifTrue: [ ^ (value at: ''code'') asString ].
  ((value includesKey: ''text'') and: [ value includesKey: ''type'' ]) ifTrue: [ ^ self displayValue: (value at: ''text'') ].
  (value at: ''ok'' ifAbsent: [ nil ]) = true ifTrue: [
   value at: ''value'' ifPresent: [ :answer | ^ self displayValue: answer ] ].
  ((value at: ''ok'' ifAbsent: [ nil ]) = false and: [ value includesKey: ''message'' ]) ifTrue: [
   ^ (value at: ''error'' ifAbsent: [ '''' ]), '': '', (value at: ''message'') ].
  ^ STONJSON toString: value ].
 (value isArray and: [ value notEmpty and: [ value allSatisfy: [ :item | item isDictionary and: [ item includesKey: ''text'' ] ] ] ])
  ifTrue: [ ^ String streamContents: [ :s | value do: [ :item | s nextPutAll: (self displayValue: item); cr ] ] ].
 ^ STONJSON toString: value'.
cls compile: 'initialize
 super initialize.
 offset := 0. pending := ByteArray new.
 items := Dictionary new. order := OrderedCollection new.
 state := ''等待事件''. changed := false. readErrors := 0'.
cls compile: 'item: anId type: aType
 ^ items at: anId ifAbsentPut: [
  order add: anId.
  Dictionary new at: ''id'' put: anId; at: ''type'' put: aType;
   at: ''text'' put: ''''; at: ''status'' put: ''进行中''; yourself ]'.
cls compile: 'poll
 | bytes start stop line |
 changed := false.
 (file notNil and: [ file exists ]) ifFalse: [ ^ false ].
 file binaryReadStreamDo: [ :stream |
  stream size < offset ifTrue: [ self reset ].
  stream position: offset.
  bytes := stream next: ((stream size - offset) min: 262144).
  offset := stream position ].
 bytes ifEmpty: [ ^ changed ].
 pending := pending , bytes.
 start := 1.
 [ stop := pending indexOf: 10 startingAt: start. stop > 0 ] whileTrue: [
  line := pending copyFrom: start to: stop - 1.
  line ifNotEmpty: [
   [ self acceptEnvelope: (STONJSON fromString: line utf8Decoded) ]
    on: Error do: [ :error | readErrors := readErrors + 1. activityCache := nil. changed := true ] ].
  start := stop + 1 ].
 start > 1 ifTrue: [ pending := pending copyFrom: start to: pending size ].
 ^ changed'.
cls compile: 'requestId ^ requestId'.
cls compile: 'requestId: anId
 requestId := anId'.
cls compile: 'reset
 revision := (revision ifNil: [ 0 ]) + 1.
 activityCache := nil. answerCache := nil.
 offset := 0. pending := ByteArray new.
 items := Dictionary new. order := OrderedCollection new.
 threadId := nil. turnId := nil.
 state := ''读取事件''. readErrors := 0. changed := true'.
cls compile: 'revision ^ revision ifNil: [ 0 ]'.
cls compile: 'safeValue: value
 "Keep tool details inspectable without copying reasoning content or credentials."
 value isDictionary ifTrue: [
  ^ Dictionary newFrom: (value associations collect: [ :assoc |
   assoc key -> ((#(''apikey'' ''api_key'' ''token'' ''access_token'' ''authorization'' ''password'' ''secret'') includes: assoc key asString asLowercase)
    ifTrue: [ ''[已隐藏]'' ] ifFalse: [ self safeValue: assoc value ]) ]) ].
 (value isArray or: [ value isKindOf: OrderedCollection ]) ifTrue: [
  ^ value collect: [ :each | self safeValue: each ] as: Array ].
 ^ value'.
cls compile: 'snapshot
 ^ order collect: [ :id | (items at: id) deepCopy ] as: Array'.
cls compile: 'hasUnreadEvents
 ^ file notNil and: [ file exists and: [ file size > offset ] ]'.
cls compile: 'visibleActivities
 ^ self snapshot select: [ :entry | | type |
  type := entry at: ''type''.
  (type = ''agentMessage'' and: [ (entry at: ''phase'' ifAbsent: [ '''' ]) = ''commentary'' ])
   or: [ (#(''reasoning'' ''plan'') includes: type)
    ifTrue: [ (entry at: ''text'') notEmpty ]
    ifFalse: [ #(''dynamicToolCall'' ''mcpToolCall'' ''commandExecution'' ''fileChange'' ''webSearch'') includes: type ] ] ]'.
cls compile: 'state ^ state'.
cls compile: 'statusLabel: entry
 (entry at: ''success'' ifAbsent: [ nil ]) = false ifTrue: [ ^ ''失败'' ].
 ^ Dictionary new
  at: ''inProgress'' put: ''执行中''; at: ''completed'' put: ''已完成'';
  at: ''failed'' put: ''失败''; at: ''interrupted'' put: ''已中断'';
  at: ''declined'' put: ''已拒绝''; at: ''pending'' put: ''等待执行'';
  at: (entry at: ''status'') ifAbsent: [ entry at: ''status'' ]'.
'conversation stream installed'
