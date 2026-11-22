answer: message
 "The first argument to replyTo:usingContext: is the user message. For audio, text contains the corrected transcript. For files, attachmentIds lists the attachments in order. Resolve each ID with LoomConversation attachment: id, then use LoomConversation fileForAttachment: attachment to get the file. Respond to this message and return the full user-facing reply as a GT String."
 | session input context correction send reply |
 session := LoomCodex session: #main.
 input := message.
 (message at: 'kind' ifAbsent: [ nil ]) = 'audio' ifTrue: [
  correction := self correctRecording: message using: session.
  input := message copy at: 'text' put: (correction at: 'text'); yourself ].
 context := self preparePrompt: input.
 send := [ session replyTo: input usingContext: context ].
 reply := correction ifNil: [ send value ] ifNotNil: [ session requireThread: (correction at: 'threadId') during: send ].
 reply isString ifFalse: [ self error: 'The Loom conversation expects a text reply' ].
 ^ reply
