"One running GT business process per tool scope. Ancestors link executions across Codex sessions."
| question scope run |
(DynamicVariable << #LMBusinessToolCall slots: #(); package: 'Loom-Codex') install.
(DynamicVariable << #LMBusinessProcess slots: #(); package: 'Loom-Codex') install.
question := (Object << #LMBusinessQuestion slots: #(id origin invocation gate answer failure); package: 'Loom-Codex') install.
scope := (Object << #LMBusinessScope slots: #(client threadId call parent record lock execution result completed closed); package: 'Loom-Codex') install.
run := (Object << #LMBusinessRun slots: #(id scope worker events lock pending delivered cancelled toolCallId); package: 'Loom-Codex') install.
question compile: 'initialize
 super initialize. id := UUID new asString. gate := Semaphore new'.
question compile: 'id ^ id'.
question compile: 'invocation ^ invocation'.
question compile: 'from: aRun message: message caller: caller
 origin := aRun.
 invocation := (Smalltalk globals at: #LMInvocation) new message: message caller: caller; yourself'.
question compile: 'description
 ^ Dictionary new at: ''kind'' put: ''subrequest''; at: ''requestId'' put: id;
  at: ''originExecutionId'' put: origin id; at: ''selector'' put: invocation message selector asString; yourself'.
question compile: 'wait
 gate wait.
 failure ifNotNil: [ self error: failure ].
 ^ answer'.
question compile: 'resolve: anObject
 answer := anObject. gate signal'.
question compile: 'fail: reason
 failure := reason. gate signal'.
scope compile: 'client: aKey call: aCall parent: aRun events: aBlock
 client := aKey. call := aCall. parent := aRun. record := aBlock. lock := Mutex new'.
scope compile: 'client ^ client'.
scope compile: 'threadId: id threadId := id'.
scope compile: 'requireThread: expected during: operation
 (expected notNil and: [ expected ~= threadId ]) ifTrue: [ self error: ''The required Codex thread changed'' ].
 ^ operation value'.
scope compile: 'parent ^ parent'.
scope compile: 'execution ^ execution'.
scope compile: 'awaitsProgram
 ^ lock critical: [ execution notNil and: [ execution awaitsProgram ] ]'.
scope compile: 'result
 ^ lock critical: [ completed = true ifFalse: [ self error: ''No completed business result'' ]. result ]'.
scope compile: 'record: phase run: run question: aQuestion
 | row |
 row := Dictionary new at: ''phase'' put: phase; at: ''executionId'' put: run id; yourself.
 run toolCallId ifNotNil: [ :tool | row at: ''toolCallId'' put: tool ].
 run parent ifNotNil: [ :p | row at: ''parentExecutionId'' put: p id ].
 aQuestion ifNotNil: [ row addAll: aQuestion description ].
 record value: call value: row'.
scope compile: 'start: aBlock
 | run |
 run := lock critical: [
  (closed = true or: [ execution notNil ]) ifTrue: [ self error: ''This turn cannot start another business execution'' ].
  result := nil. completed := false.
  execution := LMBusinessRun new scope: self; yourself ].
 ^ run start: aBlock'.
scope compile: 'request: requestId
 ^ lock critical: [ execution ifNil: [ self error: ''No pending business execution'' ].
  (execution questionWithId: requestId) invocation ]'.
scope compile: 'answer: requestId with: object
 | run |
 run := lock critical: [
  execution ifNil: [ self error: ''No pending business execution'' ].
  execution resumeQuestion: requestId with: object.
  execution ].
 ^ run nextEvent'.
scope compile: 'assertComplete
 lock critical: [ execution ifNotNil: [ self error: ''Finish the business execution before returning the outer result'' ] ]'.
scope compile: 'close
 | run |
 run := lock critical: [ | current |
  closed := true. current := execution. execution := nil. current ].
 run ifNotNil: #cancel'.
scope compile: 'finish: run value: object ok: success
 lock critical: [
  execution == run ifTrue: [ result := object. completed := success. execution := nil ] ]'.
run compile: 'scope: aScope
 scope := aScope. toolCallId := LMBusinessToolCall value. id := UUID new asString. events := SharedQueue new. lock := Mutex new'.
run compile: 'id ^ id'.
run compile: 'parent ^ scope parent'.
run compile: 'requireThread: expected during: operation
 ^ scope requireThread: expected during: operation'.
run compile: 'toolCallId ^ toolCallId'.
run compile: 'awaitsProgram
 ^ lock critical: [ cancelled ~= true and: [ delivered ~= true ] ]'.
run compile: 'ancestorFor: key
 scope client = key ifTrue: [ ^ self ].
 ^ self parent ifNotNil: [ :p | p ancestorFor: key ]'.
run compile: 'ask: message caller: caller through: destination
 | q |
 q := LMBusinessQuestion new from: self message: message caller: caller; yourself.
 destination publish: q.
 ^ q wait'.
run compile: 'publish: q
 lock critical: [
  (cancelled = true or: [ pending notNil ]) ifTrue: [ self error: ''Business execution cannot accept a second pending subrequest'' ].
  pending := q.
  scope record: ''subrequest'' run: self question: q.
  events nextPut: q description ]'.
run compile: 'questionWithId: requestId
 ^ lock critical: [
  (pending notNil and: [ pending id = requestId and: [ delivered = true ] ])
   ifFalse: [ self error: ''Subrequest does not belong to this waiting execution'' ].
  pending ]'.
run compile: 'resumeQuestion: requestId with: object
 lock critical: [
  | q |
  q := self questionWithId: requestId.
  toolCallId := LMBusinessToolCall value.
  scope record: ''answered'' run: self question: q.
  pending := nil. delivered := false.
  q resolve: object ]'.
run compile: 'start: aBlock
 [ lock critical: [ cancelled = true ifTrue: [ self error: ''Owning turn ended'' ].
   scope record: ''started'' run: self question: nil.
   worker := [
    [ | object |
     object := LMBusinessProcess value: self during: aBlock.
     events nextPut: { #done. object } ]
     on: Error do: [ :error | events nextPut: { #failed. error messageText } ] ] newProcess.
   worker name: ''Loom business '', id.
   worker resume ] ]
  on: Error do: [ :error | scope finish: self value: nil ok: false. error pass ].
 ^ self nextEvent'.
run compile: 'nextEvent
 | event object reply |
 event := events next.
 event isDictionary ifTrue: [
  lock critical: [ cancelled = true ifTrue: [ self error: ''Owning turn ended'' ]. delivered := true ].
  ^ event copy at: ''executionId'' put: id; yourself ].
 object := event second.
 scope finish: self value: object ok: event first = #done.
 scope record: event first asString run: self question: nil.
 event first = #failed ifTrue: [ self error: object ].
 reply := Dictionary new at: ''kind'' put: ''completed''; at: ''executionId'' put: id; yourself.
 [ STONJSON toString: object. reply at: ''value'' put: object ]
  on: Error do: [ :ignored | reply at: ''valueClass'' put: object class name asString ].
 ^ reply'.
run compile: 'cancel
 lock critical: [
  cancelled := true.
  pending ifNotNil: [ pending fail: ''Owning turn ended''. pending := nil ].
  events nextPut: { #failed. ''Owning turn ended'' } ].
 worker ifNotNil: [ worker isTerminated ifFalse: [ worker terminate ] ]'.
'Loom business executions installed'
