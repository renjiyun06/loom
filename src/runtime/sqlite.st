"Native SQLite access. Connections and statement handles are scoped to a database operation."
| sqlite |
sqlite := (Object << #LMSqliteDatabase slots: #(#handle); package: 'Loom-Storage') install.
sqlite compile: 'open: filename into: output
 ^ self ffiCall: #(int sqlite3_open(void* filename, void* output)) module: ''winsqlite3.dll'''.
sqlite compile: 'close: database
 ^ self ffiCall: #(int sqlite3_close(void* database)) module: ''winsqlite3.dll'''.
sqlite compile: 'prepare: sql into: output
 ^ self ffiCall: #(int sqlite3_prepare_v2(void* handle, char* sql, int -1, void* output, void* 0)) module: ''winsqlite3.dll'''.
sqlite compile: 'finalize: statement
 ^ self ffiCall: #(int sqlite3_finalize(void* statement)) module: ''winsqlite3.dll'''.
sqlite compile: 'step: statement
 ^ self ffiCall: #(int sqlite3_step(void* statement)) module: ''winsqlite3.dll'''.
sqlite compile: 'bindNull: position in: statement
 ^ self ffiCall: #(int sqlite3_bind_null(void* statement, int position)) module: ''winsqlite3.dll'''.
sqlite compile: 'bind: value at: position in: statement
 ^ self ffiCall: #(int sqlite3_bind_text(void* statement, int position, void* value, int -1, void* 0)) module: ''winsqlite3.dll'''.
sqlite compile: 'columnIn: statement
 ^ self ffiCall: #(void* sqlite3_column_text(void* statement, int 0)) module: ''winsqlite3.dll'''.
sqlite compile: 'errorPointer
 ^ self ffiCall: #(void* sqlite3_errmsg(void* handle)) module: ''winsqlite3.dll'''.
sqlite compile: 'check: result
 result = 0 ifFalse: [ self error: (self errorPointer utf8StringFromCString) ]'.
sqlite compile: 'during: operation on: file
 | output name rc |
output := ExternalAddress newPointer.
output pointerAtOffset: 0 put: ExternalAddress null.
name := ExternalAddress fromString: file fullName.
[
 rc := self open: name into: output.
 handle := output pointerAtOffset: 0.
 handle isNull ifTrue: [ self error: ''SQLite could not allocate a connection'' ].
 self check: rc.
 self execute: ''PRAGMA busy_timeout=3000;''.
 self execute: ''PRAGMA foreign_keys=ON;''.
 self execute: ''PRAGMA synchronous=FULL;''.
 ^ operation value: self
] ensure: [
 (handle notNil and: [ handle isNull not ]) ifTrue: [ self close: handle. handle := nil ].
 name free. output free ]'.
sqlite compile: 'execute: sql
 ^ self execute: sql values: #()'.
sqlite compile: 'execute: sql values: values
 | output statement buffers rows code |
output := ExternalAddress newPointer.
output pointerAtOffset: 0 put: ExternalAddress null.
buffers := OrderedCollection new.
rows := OrderedCollection new.
[
 self check: (self prepare: sql into: output).
 statement := output pointerAtOffset: 0.
 values withIndexDo: [ :item :index |
  item ifNil: [ self check: (self bindNull: index in: statement) ] ifNotNil: [
   | buffer |
   buffer := ExternalAddress fromString: item asString.
   buffers add: buffer.
   self check: (self bind: buffer at: index in: statement) ] ].
 [ (code := self step: statement) = 100 ] whileTrue: [
  | value |
  value := self columnIn: statement.
  rows add: (value isNull ifTrue: [ nil ] ifFalse: [ value utf8StringFromCString ]) ].
 code = 101 ifFalse: [ self check: code ].
 ^ rows asArray
] ensure: [
 statement ifNotNil: [ self finalize: statement ].
 buffers do: #free.
 output free ]'.
sqlite compile: 'transaction: operation
 self execute: ''BEGIN IMMEDIATE''.
^ [ | result |
 result := operation value.
 self execute: ''COMMIT''.
 result
] on: Error do: [ :error |
 self execute: ''ROLLBACK''.
 error pass ]'.
'GT SQLite installed'
