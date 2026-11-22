"Loom activity pages are queried from the Loom session database."
| cls |
cls := (Object << #LMActivityReader
 slots: #(#viewId #serial #lastQuery #fileStamp #published #channel);
 package: 'Loom-Conversation') install.
cls compile: 'initialize
 super initialize.
 viewId := UUID new asString. serial := 0. channel := ''conversation'''.
cls compile: 'channel: value channel := value'.
cls compile: 'pageOf: limit focus: invocation
 ^ self pageOf: limit focus: invocation session: nil'.
cls compile: 'pageOf: limit focus: invocation session: sessionId
 | query |
 query := { limit. invocation. sessionId }.
 lastQuery = query ifFalse: [
  (self requestPageOf: limit focus: invocation session: sessionId) ifTrue: [
   (lastQuery isNil or: [ lastQuery size < 3 or: [ lastQuery third ~= sessionId ] ]) ifTrue: [ published := nil ].
   lastQuery := query ] ].
 self readPage.
 ^ published'.
cls compile: 'requestPageOf: limit focus: invocation session: sessionId
 | directory name file query |
 directory := LoomIPC / ''activity-queries''.
 directory exists ifFalse: [ ^ false ].
 serial := serial + 1.
 name := UUID new asString.
 file := directory / (name, ''.tmp'').
 query := Dictionary new at: ''view'' put: viewId; at: ''serial'' put: serial;
  at: ''limit'' put: limit; at: ''focus'' put: invocation;
  at: ''channel'' put: channel; at: ''session'' put: sessionId; yourself.
 file writeStreamDo: [ :out | out nextPutAll: (STONJSON toString: query) ].
 file renameTo: name, ''.json''.
 ^ true'.
cls compile: 'readPage
 | file stamp page |
 file := LoomIPC / (channel = ''overview'' ifTrue: [ ''activity-overview.json'' ] ifFalse: [ ''activity-view.json'' ]).
 file exists ifFalse: [ ^ self ].
 stamp := { file modificationTime. file size }.
 fileStamp = stamp ifTrue: [ ^ self ].
 page := STONJSON fromString: file contents.
 ((page at: ''view'') = viewId and: [ (page at: ''serial'') = serial ]) ifTrue: [
  fileStamp := stamp. published := page ]'.
'Loom SQLite activity reader installed'
