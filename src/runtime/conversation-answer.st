answer: message
 "The first argument is the user message and the second is a queryable LMReplyContext. If the message refers to earlier work, use runtime_eval with the second argument: searchMail: a phrase and mailThread: a result's threadId for earlier mail, or searchConversation: a phrase and conversationMessage: a result's messageId for earlier GT chat. The prepared prompt is available as context prompt. For audio, the message text is the corrected transcript. For files, resolve attachmentIds using LoomConversation attachment: and fileForAttachment:. Return a GT Dictionary with text (the complete user-facing reply) and browserAction. Use 'none' if you did not use a browser, 'keep' if the browser may still be needed or the user is using it, and 'close' if you used it and confirmed it can be closed. Loom will handle the close in a separate call."
 | session input context correction send reply |
 session := LoomCodex session: #main.
 input := message.
 (message at: 'kind' ifAbsent: [ nil ]) = 'audio' ifTrue: [
  correction := self correctRecording: message using: session.
  input := message copy at: 'text' put: (correction at: 'text'); yourself ].
 context := LMReplyContext forConversation: input prompt: (self preparePrompt: input).
 send := [ session replyTo: input usingContext: context ].
 reply := correction ifNil: [ send value ] ifNotNil: [ session requireThread: (correction at: 'threadId') during: send ].
 ^ reply
