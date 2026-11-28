"All tool code runs in a managed process. A delivered question allows a nested tool evaluation."
| question scope run |
(DynamicVariable << #LMBusinessToolCall slots: #(); package: 'Loom-Codex') install.
(DynamicVariable << #LMBusinessProcess slots: #(); package: 'Loom-Codex') install.
question := (Object << #LMBusinessQuestion slots: #(id origin invocation gate answer failure); package: 'Loom-Codex') install.
scope := (Object << #LMBusinessScope slots: #(client threadId call parent record lock execution result completed closed toolLock); package: 'Loom-Codex') install.
run := (Object << #LMBusinessRun slots: #(id scope worker events lock pending delivered cancelled toolCallId enclosing parent stagedAnswer); package: 'Loom-Codex') install.
question compile: 'initialize
 super initialize. id := UUID new asString. gate := Semaphore new'.
question compile: 'id ^ id'.
question compile: 'origin ^ origin'.
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
scope compile: 'localExecutionAt: anId
 ^ lock critical: [ | current |
  current := execution.
  [ current notNil ] whileTrue: [
   current id = anId ifTrue: [ ^ current ].
   current := current enclosing ].
  nil ]'.
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
scope compile: 'evaluate: aBlock
 | serial |
 serial := lock critical: [ toolLock ifNil: [ toolLock := Mutex new ] ].
 ^ serial critical: [ | run |
  run := lock critical: [ | next |
   closed = true ifTrue: [ self error: ''This turn has ended'' ].
   (execution notNil and: [ execution awaitsProgram ]) ifTrue: [ self error: ''Business execution is busy'' ].
   next := LMBusinessRun new scope: self; enclosing: execution; yourself.
   self record: ''started'' run: next question: nil.
   execution := next ].
  run execute: [ aBlock value: run ] ]'.
scope compile: 'assertCanReturnFrom: run
 lock critical: [
  (closed = true or: [ execution ~~ run or: [ run enclosing notNil ] ])
   ifTrue: [ self error: ''Finish pending subrequests before returning the outer result'' ] ]'.
scope compile: 'close
 | run |
 run := lock critical: [ | current |
  closed := true. current := execution. execution := nil. current ].
 [ run notNil ] whileTrue: [
  run cancel.
  self record: ''cancelled'' run: run question: nil.
  run := run enclosing ]'.
scope compile: 'finish: run value: object ok: success
 ^ lock critical: [
  execution == run ifFalse: [ false ] ifTrue: [
   execution := run enclosing.
   execution ifNil: [ result := object. completed := success ].
   self record: (success ifTrue: [ ''done'' ] ifFalse: [ ''failed'' ]) run: run question: nil.
   true ] ]'.
run compile: 'scope: aScope
 scope := aScope. toolCallId := LMBusinessToolCall value. id := UUID new asString. events := SharedQueue new. lock := Mutex new'.
run compile: 'id ^ id'.
run compile: 'enclosing: aRun
 enclosing := aRun.
 "The local waiting point owns the answer. The sender of its question supplies the causal chain."
 parent := aRun ifNil: [ scope parent ] ifNotNil: [ aRun questionOrigin ]'.
run compile: 'enclosing ^ enclosing'.
run compile: 'parent ^ parent'.
run compile: 'questionOrigin
 ^ lock critical: [ pending origin ]'.
run compile: 'result ^ scope result'.
run compile: 'request: requestId
 enclosing ifNil: [ self error: ''No pending subrequest in this turn'' ].
 ^ (enclosing questionWithId: requestId) invocation'.
run compile: 'answer: requestId with: object
 self request: requestId.
 stagedAnswer ifNotNil: [ self error: ''This evaluation already supplied an answer'' ].
 stagedAnswer := requestId -> object.
 ^ nil'.
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
run compile: 'completionFor: object
 | feedback |
 feedback := Dictionary new at: ''kind'' put: ''completed''; at: ''executionId'' put: id; yourself.
 "Materialize the JSON value here: object serialization may itself call a session."
 [ feedback at: ''value'' put: (STONJSON fromString: (STONJSON toString: object)) ]
  on: STONWriterError do: [ :ignored | feedback at: ''valueClass'' put: object class name asString ].
 ^ feedback'.
run compile: 'execute: aBlock
 [ lock critical: [ cancelled = true ifTrue: [ self error: ''Owning turn ended'' ].
   worker := [
    [ LMBusinessProcess value: self during: [ | object feedback |
      object := aBlock value.
      feedback := self completionFor: object.
      events nextPut: { #done. object. feedback } ] ]
     on: Error do: [ :error | events nextPut: { #failed. error messageText } ] ] newProcess.
   worker name: ''Loom business '', id.
   worker resume ] ]
  on: Error do: [ :error | scope finish: self value: nil ok: false. error pass ].
 ^ self nextEvent'.
run compile: 'nextEvent
 | event |
 event := events next.
 event isDictionary ifTrue: [
  lock critical: [ cancelled = true ifTrue: [ self error: ''Owning turn ended'' ]. delivered := true ].
  ^ event copy at: ''executionId'' put: id; yourself ].
 (scope finish: self value: event second ok: event first = #done) ifFalse: [
  ^ Dictionary new at: ''kind'' put: ''failed''; at: ''executionId'' put: id; at: ''error'' put: ''Owning turn ended''; yourself ].
 event first = #failed ifTrue: [
  ^ Dictionary new at: ''kind'' put: ''failed''; at: ''executionId'' put: id; at: ''error'' put: event second; yourself ].
 stagedAnswer ifNotNil: [
  enclosing resumeQuestion: stagedAnswer key with: stagedAnswer value.
  ^ enclosing nextEvent ].
 ^ event third'.
run compile: 'cancel
 lock critical: [
  cancelled := true.
  pending ifNotNil: [ pending fail: ''Owning turn ended''. pending := nil ].
  events nextPut: { #failed. ''Owning turn ended'' } ].
 worker ifNotNil: [ worker isTerminated ifFalse: [ worker terminate ] ]'.
#(start: request: answer:with: assertComplete execution) do: [ :selector |
 (scope includesSelector: selector) ifTrue: [ scope removeSelector: selector ] ].
(run includesSelector: #start:) ifTrue: [ run removeSelector: #start: ].
'Loom business executions installed'
