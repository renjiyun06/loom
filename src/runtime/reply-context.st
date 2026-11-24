"The query interface passed with a current chat message or mail task."
| context |
context := (Object << #LMReplyContext slots: #(source messageId threadId prompt); package: 'Loom-Application') install.
context class compile: 'forConversation: message prompt: prepared
 ^ self new from: ''conversation'' message: message threadId: nil prompt: prepared'.
context class compile: 'forMail: task
 ^ self new from: ''mail'' message: task threadId: (task at: ''threadId'' ifAbsent: [ nil ]) prompt: nil'.
context compile: 'from: aSource message: message threadId: aThreadId prompt: prepared
 source := aSource.
 messageId := message at: ''id''.
 threadId := aThreadId.
 prompt := prepared.
 ^ self'.
context compile: 'source ^ source'.
context compile: 'messageId ^ messageId'.
context compile: 'threadId ^ threadId'.
context compile: 'prompt ^ prompt'.
context compile: 'searchMail: query
 | mail |
 mail := Smalltalk globals at: #LoomGtMail ifAbsent: [ ^ #() ].
 ^ mail searchHistory: query'.
context compile: 'mailThread
 ^ threadId ifNil: [ #() ] ifNotNil: [ self mailThread: threadId ]'.
context compile: 'mailThread: id
 | mail |
 mail := Smalltalk globals at: #LoomGtMail ifAbsent: [ ^ #() ].
 ^ mail threadHistory: id'.
context compile: 'conversationMessage: id
 | store |
 id ifNil: [ ^ nil ].
 store := Smalltalk globals at: #LoomConversationStore ifAbsent: [ ^ nil ].
 ^ (store historyRecordsFor: id)
  ifEmpty: [ nil ] ifNotEmpty: [ :rows | self withCorrectedText: rows first ]'.
context compile: 'searchConversation: query
 | needle store matches |
 needle := query trimBoth asLowercase.
 needle isEmpty ifTrue: [ ^ #() ].
 store := Smalltalk globals at: #LoomConversationStore ifAbsent: [ ^ #() ].
 matches := OrderedCollection new.
 (store historyRecordsFor: nil) do: [ :row |
  (source = ''conversation'' and: [ (row at: ''messageId'') = messageId ]) ifFalse: [
   | match |
   match := self conversationMatch: (self withCorrectedText: row) for: needle.
   match ifNotNil: [ matches add: match ].
   matches size = 8 ifTrue: [ ^ matches asArray ] ] ].
 ^ matches asArray'.
context compile: 'withCorrectedText: row
 | correction conversation |
 (row removeKey: ''audioId'') ifNotNil: [
  conversation := Smalltalk globals at: #LoomConversation ifAbsent: [ nil ].
  correction := conversation ifNotNil: [ conversation speechCorrectionAt: (row at: ''messageId'') ].
  (correction notNil and: [ correction at: ''ok'' ifAbsent: [ false ] ]) ifTrue: [
   row at: ''text'' put: (correction at: ''text'') ] ].
 ^ row'.
context compile: 'conversationMatch: row for: needle
 | text time role index |
 text := row at: ''text''.
 time := row at: ''sentAt''.
 role := ''user''.
 index := text asLowercase findString: needle startingAt: 1.
 index = 0 ifTrue: [
  text := (row at: ''replyText'') ifNil: [ ^ nil ].
  time := row at: ''replyAt''.
  role := ''assistant''.
  index := text asLowercase findString: needle startingAt: 1 ].
 index = 0 ifTrue: [ ^ nil ].
 ^ Dictionary new
  at: ''source'' put: ''conversation'';
  at: ''messageId'' put: (row at: ''messageId'');
  at: ''sentAt'' put: time;
  at: ''role'' put: role;
  at: ''snippet'' put: (text copyFrom: ((index - 45) max: 1) to: ((index + 135) min: text size));
  yourself'.
context
