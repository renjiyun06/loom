answer: message
 "Answer the user's request using the prepared context. Read the second argument to get that context. Return the full user-facing reply as a GT String. Keep the Loom invocation protocol out of the user-facing reply."
 | context reply |
 context := self preparePrompt: message.
 reply := (LoomCodex session: #main)
  replyTo: message usingContext: context.
 reply isString ifFalse: [ self error: 'The Loom conversation expects a text reply' ].
 ^ reply
