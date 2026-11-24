answer: message
 "The first argument is the user message. The second is a Dictionary with source, messageId, historyLookupInstructions, and historySources. Read the lookup guidance when earlier chat or mail is relevant. The prepared prompt is under 'prompt'. For audio, the message text is the corrected transcript. For files, resolve attachmentIds using LoomConversation attachment: and fileForAttachment:. Return a GT Dictionary with text (the complete user-facing reply) and browserAction. Use 'none' if you did not use a browser, 'keep' if the browser may still be needed or the user is using it, and 'close' if you used it and confirmed it can be closed. Loom will handle the close in a separate call."
 | session input context correction send reply |
 session := LoomCodex session: #main.
 input := message.
 (message at: 'kind' ifAbsent: [ nil ]) = 'audio' ifTrue: [
  correction := self correctRecording: message using: session.
  input := message copy at: 'text' put: (correction at: 'text'); yourself ].
 context := (LoomApplications replyContextFor: input from: 'conversation')
  at: 'prompt' put: (self preparePrompt: input); yourself.
 send := [ session replyTo: input usingContext: context ].
 reply := correction ifNil: [ send value ] ifNotNil: [ session requireThread: (correction at: 'threadId') during: send ].
 ^ reply
