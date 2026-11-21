"An intercepted Smalltalk send. The arguments and result stay in this image."
| invocation |
invocation := (Object << #LMInvocation
 slots: #(message caller requestId submitted result);
 package: 'Loom-Bridge') install.
Smalltalk globals at: #LoomPendingInvocations ifAbsentPut: [ Dictionary new ].
invocation class compile: 'pendingAt: id
 ^ LoomPendingInvocations at: id ifAbsent: [ self error: ''This Loom object invocation is no longer active'' ]'.
invocation compile: 'message: aMessage caller: aContext
 message := aMessage.
 caller := aContext.
 submitted := false'.
invocation compile: 'attachTo: id
 requestId := id.
 LoomPendingInvocations at: id put: self'.
invocation compile: 'detach
 requestId ifNotNil: [
  LoomPendingInvocations removeKey: requestId ifAbsent: [ ].
  requestId := nil ]'.
invocation compile: 'evaluate: toolCode sessionId: sessionId
 | value |
 value := toolCode valueWithArguments: { caller. message. sessionId. [ :object | self return: object ] }.
 ^ { submitted. value }'.
invocation compile: 'return: anObject
 requestId ifNil: [ self error: ''This Loom object invocation is no longer active'' ].
 submitted ifTrue: [
  result == anObject ifFalse: [ self error: ''This invocation already has a different return object'' ].
  ^ true ].
 result := anObject.
 submitted := true.
 ^ true'.
invocation compile: 'result
 submitted ifFalse: [ self error: ''Codex did not return a GT object for '', message selector asString ].
 ^ result'.
#(selector arguments argumentAt: caller hasResult markedCallerSource prompt) do: [ :selector |
 (invocation includesSelector: selector) ifTrue: [ invocation removeSelector: selector ] ].
LMCodexClient compile: 'doesNotUnderstand: message
 | invocation |
 Processor activeProcess == BridgeMailboxProcess ifTrue: [
  self error: ''Call LoomCodex from an independent GT Process, not from the runtime tool callback'' ].
 BlWinitHost uiProcessDo: [ :process |
  process == Processor activeProcess ifTrue: [
   self error: ''Call LoomCodex from an independent GT Process to keep the desktop responsive'' ] ].
 invocation := LMInvocation new message: message caller: thisContext sender; yourself.
 ^ mutex critical: [
  [ self performRequest: ''Loom 调用了你。'' action: ''ask'' invocation: invocation.
    invocation result ]
   ensure: [ invocation detach. activeRequestId := nil ] ]'.
LMCodexClient class compile: 'bridgeVersion ^ 12'.
'Loom object invocation installed'
