answer: message
 "The first argument is the user message and the second is its prepared context. A message with kind audio has the transcript in text. Return the full user-facing reply as a GT String. Keep the Loom invocation protocol out of the user-facing reply."
 | context reply |
 context := self preparePrompt: message.
 reply := (LoomCodex session: #main)
  replyTo: message usingContext: context.
 reply isString ifFalse: [ self error: 'The Loom conversation expects a text reply' ].
 ^ reply
