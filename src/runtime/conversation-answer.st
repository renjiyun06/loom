answer: message
 "The arguments are the user message and an LMReplyContext. Its prompt is the prepared text. Its history objects provide databaseFile for custom read-only queries when earlier records are relevant. For audio, the message text is the corrected transcript. For files, resolve attachmentIds using context conversation attachment: and fileForAttachment:.
 When the user asks to hear a joke, evaluate LoomJoke runIn: loomRun. Answer its subrequest with a joke that fits the user's request. Use the joke returned by the resumed program as the reply text.
 Return a GT Dictionary with text (the complete user-facing reply) and browserAction. Use 'none' if you did not use a browser, 'keep' if the browser may still be needed or the user is using it, and 'close' if you used it and confirmed it can be closed. Loom will handle the close in a separate call."
 | session input context correction send reply |
 session := LoomCodex session: #main.
 input := message.
 (message at: 'kind' ifAbsent: [ nil ]) = 'audio' ifTrue: [
  correction := self correctRecording: message using: session.
  input := message copy at: 'text' put: (correction at: 'text'); yourself ].
 context := (LoomApplications replyContextFor: input from: 'conversation')
  prompt: (self preparePrompt: input); yourself.
 send := [ session replyTo: input usingContext: context ].
 reply := correction ifNil: [ send value ] ifNotNil: [ session requireThread: (correction at: 'threadId') during: send ].
 ^ reply
