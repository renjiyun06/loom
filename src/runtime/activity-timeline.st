"Read activity summaries and changes outside the graphics process."
| cls previous |
previous := Smalltalk globals at: #LMActivityReader ifAbsent: [ nil ].
previous ifNotNil: [
 #(initialize pageOf:focus: pageOf:focus:session: requestPageOf:focus:session: readPage) do: [ :selector |
  (previous includesSelector: selector) ifTrue: [ previous removeSelector: selector ] ] ].
cls := (Object << #LMActivityReader
 slots: #(registry channel selection loadedLimit first revision older published replyKey replyText);
 package: 'Loom-Conversation') install.
cls compile: 'channel: value channel := value'.
cls compile: 'registry: value registry := value'.
cls compile: 'registry
 ^ registry ifNil: [ registry := LoomNativeCodexHost registry ]'.
cls compile: 'pageOf: limit session: sessionId
 | snapshot batch items previous managed |
 managed := channel = ''overview''.
 (published isNil or: [ selection ~= sessionId or: [ limit < loadedLimit ] ]) ifTrue: [
  snapshot := self registry activitySummariesBefore: nil limit: limit session: sessionId managedOnly: managed.
  selection := sessionId.
  revision := snapshot at: ''revision''.
  older := snapshot at: ''older''.
  items := snapshot at: ''items''.
  first := items ifEmpty: [ nil ] ifNotEmpty: [ items first at: ''seq'' ].
  ^ self publish: items limit: limit ].
 previous := published at: ''items''.
 items := previous.
 limit > loadedLimit ifTrue: [
  snapshot := self registry activitySummariesBefore: first limit: limit - loadedLimit
   session: sessionId managedOnly: managed.
  older := snapshot at: ''older''.
  (snapshot at: ''items'') ifNotEmpty: [ :earlier |
   first := earlier first at: ''seq''.
   items := earlier, items ] ].
 batch := self registry activityChangesAfter: revision from: first session: sessionId managedOnly: managed.
 revision := batch first.
 batch second ifNotEmpty: [ :changes | items := self merge: changes into: items ].
 first ifNil: [ items ifNotEmpty: [ first := items first at: ''seq'' ] ].
 (items == previous and: [ limit = loadedLimit ]) ifTrue: [ ^ published ].
 ^ self publish: items limit: limit'.
cls compile: 'publish: items limit: limit
 loadedLimit := limit.
 ^ published := Dictionary new at: ''items'' put: items; at: ''older'' put: older;
  at: ''limit'' put: limit; at: ''session'' put: selection; yourself'.
cls compile: 'merge: changes into: items
 | merged index changed |
 merged := OrderedCollection new: items size + changes size.
 index := 1.
 changed := false.
 changes do: [ :item | | sequence |
  sequence := item at: ''seq''.
  [ index <= items size and: [ ((items at: index) at: ''seq'') < sequence ] ] whileTrue: [
   merged add: (items at: index). index := index + 1 ].
  (index <= items size and: [ ((items at: index) at: ''seq'') = sequence ]) ifTrue: [
   index := index + 1. changed := true ].
  (item at: ''visible'') = 1 ifTrue: [ merged add: item. changed := true ] ].
 changed ifFalse: [ ^ items ].
 index to: items size do: [ :position | merged add: (items at: position) ].
 ^ merged asArray'.
cls compile: 'streamedReplyFor: invocation
 | key |
 invocation ifNil: [ replyKey := nil. replyText := ''''. ^ replyText ].
 key := { invocation. self registry revision }.
 replyKey = key ifFalse: [
  replyText := self registry activityAnswerFor: invocation.
  replyKey := key ].
 ^ replyText'.
'Loom incremental activity reader installed'
