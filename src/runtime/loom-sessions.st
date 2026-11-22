"Persistent Loom session identities are resolved by the Node session registry."
| manager |
manager := (Object << #LoomSessions slots: #(); package: 'Loom-Codex') install.
Smalltalk globals at: #LoomSessionClients ifAbsentPut: [ Dictionary new ].
Smalltalk globals at: #LoomSessionClientsMutex ifAbsentPut: [ Mutex new ].
manager class compile: 'mainId ^ ''main'''.
manager class compile: 'session: identifier
 | id |
 id := self normalizedId: identifier.
 id = self mainId ifTrue: [ ^ Smalltalk globals at: #LoomCodex ].
 ^ LoomSessionClientsMutex critical: [
  LoomSessionClients at: id ifAbsentPut: [ | record |
   record := self register: id.
   LMCodexClient new clientKey: (record at: ''clientKey'');
    synchronizeThreadId: (record at: ''threadId''); yourself ] ]'.
manager class compile: 'normalizedId: identifier
 (identifier isString or: [ identifier isSymbol ]) ifFalse: [ self error: ''Use a Loom session ID'' ].
 ^ identifier asString'.
manager class compile: 'list ^ self command: ''list'' for: nil'.
manager class compile: 'show: id ^ self command: ''show'' for: (self normalizedId: id)'.
manager class compile: 'register: id ^ self command: ''register'' for: (self normalizedId: id)'.
manager class compile: 'rotate: identifier
 | id record client |
 id := self normalizedId: identifier.
 record := self command: ''rotate'' for: id.
 client := id = self mainId ifTrue: [ Smalltalk globals at: #LoomCodex ]
  ifFalse: [ LoomSessionClients at: id ifAbsent: [ nil ] ].
 client ifNotNil: [ client synchronizeThreadId: (record at: ''threadId'') ].
 ^ record'.
(manager class includesSelector: #stop:) ifTrue: [ manager class removeSelector: #stop: ].
manager class compile: 'command: action for: sessionId
 | state instance name temporary responseFile deadline response |
 state := STONJSON fromString: (LoomIPC / ''runtime-status.json'') contents.
 instance := state at: ''sessionControl'' ifAbsent: [ nil ].
 ((state at: ''status'') = ''ready'' and: [ instance notNil ])
  ifFalse: [ self error: ''Loom session management is not ready'' ].
 name := UUID new asString.
 temporary := LoomIPC / ''session-requests'' / (name, ''.tmp'').
 responseFile := LoomIPC / ''session-responses'' / (name, ''.json'').
 temporary writeStreamDo: [ :stream |
  stream nextPutAll: (STONJSON toString: (Dictionary new
   at: ''instance'' put: instance; at: ''action'' put: action; at: ''sessionId'' put: sessionId; yourself)) ].
 temporary renameTo: responseFile basename.
 deadline := DateAndTime now + 10 seconds.
 [ responseFile exists ] whileFalse: [
  DateAndTime now > deadline ifTrue: [ self error: ''Loom session command timed out'' ].
  (Delay forMilliseconds: 40) wait ].
 response := STONJSON fromString: responseFile contents.
 responseFile delete.
 (response at: ''ok'') ifFalse: [ self error: (response at: ''error'') ].
 ^ response at: ''value'''.
LMCodexClient compile: 'session: id ^ LoomSessions session: id'.
'Loom session management installed'
