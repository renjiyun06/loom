"Conversation SQLite schema and attachment files."
| store |
store := (Object << #LMConversationStore slots: #(#directory #mutex #revision); package: 'Loom-Conversation') install.
store class compile: 'isImageExtension: extension
 ^ #(''png'' ''jpg'' ''jpeg'' ''gif'' ''bmp'') includes: extension asLowercase'.
store compile: 'directory: file
 directory := file.
mutex := Mutex new.
revision := UUID new asString.'.
store compile: 'revision
 ^ revision'.
store compile: 'database: operation
 ^ mutex critical: [
 LMExecution nativeStateCritical: [
  LMSqliteDatabase new during: operation on: directory / ''conversation.sqlite'' ] ]'.
store compile: 'initializeStorage
 directory ensureCreateDirectory.
self database: [ :db |
 #(''PRAGMA journal_mode=WAL''
   ''CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY)''
   ''CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE, audio_id TEXT UNIQUE, data TEXT NOT NULL)''
   ''CREATE TABLE IF NOT EXISTS replies (id TEXT PRIMARY KEY REFERENCES messages(id), data TEXT NOT NULL)''
   ''CREATE TABLE IF NOT EXISTS staged_browser_replies (id TEXT PRIMARY KEY REFERENCES messages(id), data TEXT NOT NULL)''
   ''CREATE TABLE IF NOT EXISTS attachments (id TEXT PRIMARY KEY, message_id TEXT NOT NULL REFERENCES messages(id), data TEXT NOT NULL)''
   ''CREATE INDEX IF NOT EXISTS attachments_message ON attachments(message_id)'') do: [ :sql | db execute: sql ].
 db transaction: [
  (db execute: ''SELECT 1 FROM metadata WHERE key=''''legacy-imported'''''') ifEmpty: [
   (self legacyRecords: ''inputs'') do: [ :each | self insertMessage: each on: db ].
   (self legacyRecords: ''replies'') do: [ :each | self saveReply: each on: db ].
   db execute: ''INSERT INTO metadata VALUES (''''legacy-imported'''')'' ] ] ]'.
store compile: 'legacyRecords: folder
 | target |
target := directory / folder.
target exists ifFalse: [ ^ #() ].
^ (target files select: [ :file | file extension = ''json'' ]) collect: [ :file |
 | record |
 record := STONJSON fromString: file contents.
 (record at: ''id'') = file basenameWithoutExtension
  ifFalse: [ self error: ''Invalid legacy record: '', file basename ].
 record ]'.
store compile: 'insertMessage: message on: db
 db execute: ''INSERT INTO messages VALUES (?, ?, ?, ?)'' values:
 { message at: ''id''. message at: ''sequence''. message at: ''audioId'' ifAbsent: [ nil ]. STONJSON toString: message }'.
store compile: 'saveReply: reply on: db
 db execute: ''INSERT INTO replies VALUES (?, ?) ON CONFLICT(id) DO NOTHING'' values:
 { reply at: ''id''. STONJSON toString: reply }'.
store compile: 'saveReply: reply
 self database: [ :db |
 db transaction: [
  self saveReply: reply on: db.
  db execute: ''DELETE FROM staged_browser_replies WHERE id=?'' values: {reply at: ''id''} ].
 revision := UUID new asString ].
^ true'.
store compile: 'stageBrowserReply: reply
 ^ self database: [ :db |
  db execute: ''INSERT INTO staged_browser_replies VALUES (?, ?) ON CONFLICT(id) DO NOTHING'' values:
   { reply at: ''id''. STONJSON toString: reply } ]'.
store compile: 'stagedBrowserReplyAt: id
 ^ self database: [ :db |
  (db execute: ''SELECT data FROM staged_browser_replies WHERE id=?'' values: {id})
   ifEmpty: [ nil ] ifNotEmpty: [ :rows | STONJSON fromString: rows first ] ]'.
store compile: 'records
 ^ self database: [ :db |
 | replies attachments |
 replies := Dictionary new.
 attachments := Dictionary new.
 (self all: ''SELECT data FROM replies'' on: db) do: [ :item | replies at: (item at: ''id'') put: item ].
 (self all: ''SELECT data FROM attachments'' on: db) do: [ :item | attachments at: (item at: ''id'') put: item ].
 (self all: ''SELECT data FROM messages ORDER BY sequence'' on: db) collect: [ :item |
  replies at: (item at: ''id'') ifPresent: [ :reply | item at: ''reply'' put: reply ].
  item at: ''attachmentIds'' ifPresent: [ :ids | item at: ''attachments'' put: (ids collect: [ :id | attachments at: id ]) ].
  item ] ]'.
store compile: 'pending
 ^ self database: [ :db | self all: ''SELECT m.data FROM messages m WHERE NOT EXISTS (SELECT 1 FROM replies r WHERE r.id=m.id) ORDER BY m.sequence'' on: db ]'.
store compile: 'audioMessages
 ^ self database: [ :db | self all: ''SELECT data FROM messages WHERE audio_id IS NOT NULL'' on: db ]'.
store compile: 'all: sql on: db
 ^ (db execute: sql) collect: [ :json | STONJSON fromString: json ]'.
store compile: 'attachment: id
 ^ self database: [ :db |
 (db execute: ''SELECT data FROM attachments WHERE id=?'' values: {id}) ifEmpty: [ nil ]
  ifNotEmpty: [ :rows | STONJSON fromString: rows first ] ]'.
store compile: 'saveSource: source into: attachment
 | file |
file := directory resolve: (attachment at: ''relativePath'').
file parent ensureCreateDirectory.
source copyTo: file'.
store compile: 'attachmentForSource: source
 | id extension file |
source isFile ifFalse: [ self error: ''附件必须是可读取的文件：'', source basename ].
id := UUID new asString.
extension := source extension asLowercase.
file := (extension isNotEmpty and: [ extension size <= 16 and: [
 extension allSatisfy: [ :each | ''abcdefghijklmnopqrstuvwxyz0123456789'' includes: each ] ] ])
 ifTrue: [ ''original.'', extension ] ifFalse: [ ''original'' ].
^ Dictionary new at: ''id'' put: id; at: ''name'' put: source basename;
 at: ''relativePath'' put: (''attachments/'', id, ''/'', file);
 at: ''image'' put: (self class isImageExtension: extension); yourself'.
store compile: 'discardAttachment: attachment
 | file |
file := directory resolve: (attachment at: ''relativePath'').
file ensureDelete.
file parent ensureDelete'.
store compile: 'existingMessage: id audio: audioId on: db
 ^ (db execute: ''SELECT id FROM messages WHERE id=? OR audio_id=?'' values: {id. audioId})
 ifEmpty: [ nil ] ifNotEmpty: [ :rows | rows first ]'.
store compile: 'submit: request
 | id audioId files text attachments committed existing result |
id := request at: ''id''.
audioId := request at: ''audioId'' ifAbsent: [ nil ].
files := request at: ''files'' ifAbsent: [ #() ].
text := request at: ''text''.
(text isString and: [ text size <= 50000 and: [
 text trimBoth isNotEmpty or: [ audioId notNil or: [ files isNotEmpty ] ] ] ])
 ifFalse: [ self error: ''消息内容或附件无效'' ].
existing := self database: [ :db | self existingMessage: id audio: audioId on: db ].
existing ifNotNil: [ ^ existing ].
(request at: ''recordedMessageId'' ifAbsent: [ nil ]) ifNotNil: [ self error: ''此音频已发送'' ].
attachments := OrderedCollection new.
committed := false.
[
 files do: [ :sourcePath |
  | source entry |
  source := sourcePath asFileReference.
  entry := self attachmentForSource: source.
  attachments add: entry.
  self saveSource: source into: entry ].
 result := self database: [ :db |
  db transaction: [ | previous sequence message |
   previous := self existingMessage: id audio: audioId on: db.
   previous ifNil: [
    sequence := (db execute: ''SELECT coalesce(max(sequence), 0) + 1 FROM messages'') first asNumber.
    message := Dictionary new at: ''id'' put: id; at: ''sequence'' put: sequence;
     at: ''text'' put: text; at: ''createdAt'' put: (request at: ''createdAt''); yourself.
    audioId ifNotNil: [ message at: ''audioId'' put: audioId ].
    attachments ifNotEmpty: [ message at: ''attachmentIds'' put: (attachments collect: [ :entry | entry at: ''id'' ]) asArray ].
    self insertMessage: message on: db.
    attachments do: [ :entry |
     db execute: ''INSERT INTO attachments VALUES (?, ?, ?)'' values:
       { entry at: ''id''. id. STONJSON toString: entry } ] ].
   previous ]
 ].
 committed := result isNil.
 committed ifTrue: [ revision := UUID new asString ].
 ^ result ifNil: [ id ]
] ensure: [ committed ifFalse: [ attachments do: [ :each | self discardAttachment: each ] ] ]'.
'GT conversation SQLite installed'
