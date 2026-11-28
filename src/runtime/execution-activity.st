"Short, side-effect-free summaries for live execution values and panel rows."
| activity |
activity := (Object << #LMExecutionActivity slots: #(); package: 'Loom-Codex') install.
activity class compile: 'clip: aString
 aString size <= 180 ifTrue: [ ^ aString ].
 ^ (aString first: 179), ''…'''.
activity class compile: 'preview: anObject
 ^ self preview: anObject depth: 0'.
activity class compile: 'preview: anObject depth: depth
 | type pieces keys |
 type := anObject class.
 (#(ByteString WideString ByteSymbol WideSymbol) includes: type name) ifTrue: [
  ^ (self clip: anObject asString) withLineEndings: Character space asString ].
 anObject == nil ifTrue: [ ^ ''nil'' ].
 (#(True False SmallInteger BoxedFloat64 SmallFloat64) includes: type name) ifTrue: [ ^ anObject asString ].
 (#(LargePositiveInteger LargeNegativeInteger) includes: type name) ifTrue: [ ^ self clip: anObject asString ].
 type == Array ifTrue: [
  depth >= 2 ifTrue: [ ^ anObject size asString, '' 项'' ].
  pieces := (anObject first: (anObject size min: 3)) collect: [ :v | self preview: v depth: depth + 1 ].
  ^ self clip: ''['', (''，'' join: pieces), (anObject size > 3 ifTrue: [ ''，…'' ] ifFalse: [ '''' ]), '']'' ].
 (type == Dictionary or: [ type == OrderedDictionary ]) ifTrue: [
  (depth >= 2 or: [ anObject size > 32 ]) ifTrue: [ ^ anObject size asString, '' 个字段'' ].
  keys := anObject keys select: [ :k | #(ByteString WideString ByteSymbol WideSymbol) includes: k class name ].
  keys := keys asSortedCollection asArray.
  pieces := (keys first: (keys size min: 3)) collect: [ :k | k asString, '' = '',
   ((self sensitive: k) ifTrue: [ ''[已隐藏]'' ] ifFalse: [ self preview: (anObject at: k) depth: depth + 1 ]) ].
  ^ self clip: ''{'', (''，'' join: pieces), (anObject size > pieces size ifTrue: [ ''，…'' ] ifFalse: [ '''' ]), ''}'' ].
 ^ type name asString, '' 对象'''.
activity class compile: 'sensitive: key
 ^ #(''apikey'' ''api_key'' ''token'' ''access_token'' ''authorization'' ''password'' ''secret'') anySatisfy: [ :word | key asLowercase includesSubstring: word ]'.
activity class compile: 'question: message
 | args |
 (self sensitive: message selector asString) ifTrue: [ ^ ''[已隐藏]'' ].
 args := message arguments.
 args isEmpty ifTrue: [ ^ message selector asString ].
 ^ args size = 1 ifTrue: [ self preview: args first ] ifFalse: [ self preview: args ]'.
activity class compile: 'actionFor: source
 | tree nodes sends sendsTo |
 (source isString and: [ source size <= 16000 ]) ifFalse: [ ^ ''执行 Smalltalk'' ].
 tree := [ RBParser parseExpression: source ] on: Error do: [ :e | ^ ''执行 Smalltalk'' ].
 nodes := tree allChildren reject: [ :n | n allParents anySatisfy: #isBlock ].
 sends := nodes select: #isMessage.
 sendsTo := [ :receiver :selector | sends anySatisfy: [ :n | n selector = selector and: [
  n receiver isVariable and: [ n receiver name = receiver ] ] ] ].
 (sendsTo value: ''loomReturn'' value: #value:) ifTrue: [ ^ ''交回结果'' ].
 (sendsTo value: ''loomRun'' value: #answer:with:) ifTrue: [ ^ ''答复提问'' ].
 (sendsTo value: ''loomRun'' value: #request:) ifTrue: [ ^ ''查看提问'' ].
 (sendsTo value: ''LMExecution'' value: #checkpoint) ifTrue: [ ^ ''保存检查点'' ].
 (nodes anySatisfy: [ :n | n isVariable and: [ n name = ''loomCaller'' ] ]) ifTrue: [ ^ ''查看调用栈'' ].
 (nodes anySatisfy: [ :n | n isVariable and: [ n name = ''loomMessage'' ] ]) ifTrue: [ ^ ''查看调用消息'' ].
 (sends anySatisfy: [ :n | n selector = #sourceCode ]) ifTrue: [ ^ ''读取方法源码'' ].
 (sends anySatisfy: [ :n | n selector = #compile: ]) ifTrue: [ ^ ''编译方法'' ].
 (tree isMessage and: [ tree receiver isVariable ]) ifTrue: [
  ^ ''调用 '', tree receiver name asString, '' '', tree selector asString ].
 ^ ''执行 Smalltalk'''.
activity class compile: 'titleFor: run
 | phase action |
 phase := run at: ''phase''. action := run at: ''action''.
 phase = ''subrequest'' ifTrue: [ ^ action, '' · 等待答复'' ].
 phase = ''failed'' ifTrue: [ ^ action, ''失败'' ].
 phase = ''cancelled'' ifTrue: [ ^ action, '' · 已取消'' ].
 phase = ''unknown'' ifTrue: [ ^ action, '' · 结束状态未记录'' ].
 (phase = ''done'' and: [ action = ''保存检查点'' and: [ run includesKey: ''checkpointId'' ] ]) ifTrue: [ ^ ''检查点已保存'' ].
 ^ action'.
activity class compile: 'localTime: timestamp
 | local |
 local := [ (DateAndTime fromString: timestamp) asLocal ] on: Error do: [ :ignored | ^ timestamp ].
 ^ local asDate yyyymmdd, '' '', local asTime print24'.
activity class compile: 'detailFor: run
 ^ String streamContents: [ :out |
  out nextPutAll: ''发起会话　''; nextPutAll: (run at: ''session''); lf;
   nextPutAll: ''开始　''; nextPutAll: (self localTime: (run at: ''startedAt'')).
  run at: ''endedAt'' ifPresent: [ :at | out lf; nextPutAll: ''结束　''; nextPutAll: (self localTime: at) ].
  run at: ''durationMs'' ifPresent: [ :ms | out lf; nextPutAll: ''耗时　''; nextPutAll: ms asString; nextPutAll: '' ms'' ].
  (run at: ''questions'' ifAbsent: [ #() ]) do: [ :q |
   out lf; lf; nextPutAll: (q at: ''from''); nextPutAll: '' 向 ''; nextPutAll: (q at: ''to''); nextPutAll: '' 提问''; lf;
    nextPutAll: (q at: ''selector''); nextPutAll: ''　''; nextPutAll: (q at: ''question'' ifAbsent: [ ''未记录问题内容'' ]).
   q at: ''answeredAt'' ifPresent: [ :at | out lf; nextPutAll: (q at: ''to''); nextPutAll: '' 答复　'';
    nextPutAll: (q at: ''answer'' ifAbsent: [ ''未记录答复内容'' ]); lf; nextPutAll: (q at: ''from''); nextPutAll: '' 可继续执行'' ]
   ifAbsent: [ out lf; nextPutAll: ''尚无答复记录'' ].
   out lf; nextPutAll: ''问题编号　''; nextPutAll: (q at: ''requestId'') ].
  ((run includesKey: ''checkpointId'') and: [ (run at: ''summary'') = (''结果　'', (run at: ''checkpointId'')) ]) ifFalse: [
   out lf; lf; nextPutAll: (run at: ''summary'') ].
  run at: ''checkpointId'' ifPresent: [ :id | out lf; nextPutAll: ''检查点编号　''; nextPutAll: id.
   run at: ''checkpointAt'' ifPresent: [ :at | out lf; nextPutAll: ''保存时间　''; nextPutAll: (self localTime: at) ] ].
  out lf; nextPutAll: ''执行编号　''; nextPutAll: (run at: ''id'').
  run at: ''parentExecutionId'' ifPresent: [ :id | out lf; nextPutAll: ''上层执行编号　''; nextPutAll: id ] ]'.
activity class compile: 'updateQuestionIn: run event: event from: from to: to
 | id questions question |
 id := event at: ''requestId''. questions := run at: ''questions'' ifAbsent: [ #() ].
 question := questions detect: [ :q | (q at: ''requestId'') = id ] ifNone: [
  | new |
  new := Dictionary new at: ''requestId'' put: id; at: ''from'' put: from; at: ''to'' put: to; at: ''selector'' put: (event at: ''selector''); yourself.
  run at: ''questions'' put: (questions copyWith: new). new ].
 (event at: ''phase'') = ''subrequest'' ifTrue: [
  question at: ''askedAt'' put: (event at: ''at'').
  event at: ''question'' ifPresent: [ :v | question at: ''question'' put: v ].
  run at: ''status'' put: ''pending''; at: ''summary'' put: (from, '' 向 '', to, '' 提问　'', (event at: ''question'' ifAbsent: [ event at: ''selector'' ])) ]
 ifFalse: [
  question at: ''answeredAt'' put: (event at: ''at'').
  event at: ''answer'' ifPresent: [ :v | question at: ''answer'' put: v ].
  run at: ''status'' put: ''inProgress''; at: ''summary'' put: (to, '' 已答复 '', from, ''　'', (event at: ''answer'' ifAbsent: [ event at: ''selector'' ])) ]'.
'Loom execution activity presentation installed'
