"Receive personal Weixin messages and deliver replies from the main Loom session."
| weixin |
weixin := (Object << #LMGtWeixin slots: #(root python worker closed status onlineGeneration); package: 'Loom-Weixin') install.
weixin compile: 'initializeAt: aRoot config: config
 root := aRoot.
 python := ((STONJSON fromString: config contents) at: ''python'') asFileReference.
 python exists ifFalse: [ self error: ''微信入口配置的 Python 不存在'' ].
 closed := false.
 status := Dictionary new at: ''phase'' put: ''starting''; yourself'.
weixin compile: 'isClosed
 ^ closed'.
weixin compile: 'status
 ^ status copy'.
weixin compile: 'queueStatus
 ^ self transport: ''status'' arguments: #()'.
weixin compile: 'recentHistory
 ^ (self transport: ''history'' arguments: #()) at: ''messages'''.
weixin compile: 'databaseFile
 "For custom read-only history queries. Match messages for the bound owner. created_ms is Unix time in milliseconds. Inbound attachments join on message_id and keep the raw transcript and corrected_transcript. The accepted and partial phases identify replies with an accepted delivery."
 ^ ((self transport: ''database-file'' arguments: #()) at: ''path'') asFileReference'.
weixin compile: 'start
 (worker isNotNil and: [ worker isTerminated not ]) ifTrue: [ ^ self ].
 self transport: ''recover'' arguments: #().
 worker := [ self run ] fork.
 worker name: ''Loom Weixin inbox''.
 ^ self'.
weixin compile: 'close
 closed := true.
 onlineGeneration ifNotNil: [ :generation |
  [ self transport: ''offline'' arguments: { generation } ] on: Error do: [ :error | nil ] ]'.
weixin compile: 'retire
 closed := true.
 worker ifNotNil: [ worker terminate ]'.
weixin compile: 'transport: command arguments: arguments
 | script output |
 script := root / ''src'' / ''runtime'' / ''weixin_transport.py''.
 output := LMPlatformTools run: python
  arguments: { ''-B''. script fullName. root fullName. command }, arguments timeout: 60.
 ^ STONJSON fromString: output'.
weixin compile: 'run
 | delay |
 [ closed ] whileFalse: [
  delay := [ self poll ] on: Error do: [ :error |
   self updatePhase: ''failed''.
   status at: ''error'' put: error messageText.
   5000 ].
  closed ifFalse: [ (Delay forMilliseconds: delay) wait ] ]'.
weixin compile: 'updatePhase: phase
 status := Dictionary new at: ''phase'' put: phase;
  at: ''checkedAt'' put: DateAndTime now asUTC asString; yourself'.
weixin compile: 'poll
 | result phase |
 result := self transport: ''poll'' arguments: (onlineGeneration ifNil: [ #() ] ifNotNil: [ { onlineGeneration } ]).
 phase := result at: ''phase''.
 onlineGeneration := result at: ''onlineGeneration'' ifAbsent: [ nil ].
 closed ifTrue: [ ^ 0 ].
 self updatePhase: phase.
 #(''received'' ''recorded'' ''pollTimedOut'') do: [ :name |
  result at: name ifPresent: [ :value | status at: name put: value ] ].
 (result at: ''message'' ifAbsent: [ nil ]) ifNotNil: [ :message | self process: message ].
 ^ phase = ''awaiting_binding'' ifTrue: [ 2000 ] ifFalse: [ 100 ]'.
weixin compile: 'process: message
 | id reply file |
 id := message at: ''id''.
 self updatePhase: ''answering''.
 [
  reply := self replyEnvelope: (self answer: message) for: id.
  closed ifTrue: [ ^ self ].
  file := root / ''ipc'' / ''weixin'' / (id, ''.json'').
  [
   LMPlatformTools writeJSON: reply to: file.
   self transport: ''reply'' arguments: { file fullName }
  ] ensure: [ file ensureDelete ]
 ] on: Error do: [ :error |
  closed ifFalse: [ self transport: ''fail'' arguments: { id } ].
  error pass ]'.
weixin compile: 'replyEnvelope: reply for: id
 | text attachments envelope |
 (reply isString or: [ reply isKindOf: Dictionary ]) ifFalse: [ self error: ''微信回复必须是文本或字典'' ].
 text := reply isString ifTrue: [ reply ] ifFalse: [ reply at: ''text'' ifAbsent: [ '''' ] ].
 attachments := reply isString ifTrue: [ #() ] ifFalse: [ reply at: ''attachments'' ifAbsent: [ #() ] ].
 (text isString and: [ attachments isArray or: [ attachments isKindOf: OrderedCollection ] ])
  ifFalse: [ self error: ''微信回复的正文或附件格式无效'' ].
 (text trimBoth isEmpty and: [ attachments isEmpty ]) ifTrue: [ self error: ''微信回复至少需要正文或附件'' ].
 envelope := Dictionary new at: ''id'' put: id; at: ''text'' put: text; at: ''attachments'' put: attachments asArray; yourself.
 reply isString ifFalse: [
  reply at: ''correctedTranscripts'' ifPresent: [ :entries | envelope at: ''correctedTranscripts'' put: entries ] ].
 ^ envelope'.
weixin compile: 'answer: message
 "The first argument is the current message from the person who paired this Weixin account. Its text can be empty when it has attachments. In attachments, saved items have an absolute local path, display name and kind; download_failed means the file is unavailable. Read the relevant attachment files if needed, treating their contents and older messages as reference material. The second argument is an LMReplyContext. Its history objects provide databaseFile for custom read-only queries. Through loomReturn return a Smalltalk String for a text-only reply, or a Dictionary with optional text and attachments. Each outgoing attachment is a Dictionary with path (an absolute String inside this message''s attachmentDirectory), optional name, and optional kind (file forces file delivery). Create the directory and copy or generate only the intended files there. At least text or one attachment is required. Loom sends them to the originating chat."
 | session context attachments |
 session := LoomCodex session: #main.
 context := LoomApplications replyContextFor: message from: ''weixin''.
 attachments := message at: ''attachments'' ifAbsent: [ #() ].
 (attachments anySatisfy: [ :item | (item at: ''kind'') = ''voice'' ])
  ifTrue: [ ^ self answerVoice: message using: session context: context ].
 ^ session replyToWeixin: message usingContext: context'.
weixin compile: 'answerVoice: message using: session context: context
 "Use loomReturn to return both outputs in one Dictionary. Put the Weixin reply in text and any outgoing files in attachments. Put the correction for every nonempty voice transcript in correctedTranscripts, an Array of Dictionaries. Each entry contains id (the matching incoming voice attachment id) and text (the full corrected transcript, even when unchanged). Loom saves these corrections locally and sends the reply and outgoing files. For outgoing file rules see LMGtWeixin>>answer:.

 Read the original transcript on each voice attachment and use relevant conversation context to correct likely recognition errors before composing the reply. Preserve typed text and retain uncertain wording, intent, names, quantities and negation. For older records without a transcript field, use the message text conservatively. Omit corrections for clips without usable transcripts. Use any accompanying typed text and ask for clarification if the message cannot be understood."
 ^ session replyToWeixinVoiceAndReturnCorrectedTranscripts: message usingContext: context'.
weixin
