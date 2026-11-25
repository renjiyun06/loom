"An intercepted Smalltalk send. The arguments and result stay in this image."
| invocation |
invocation := (Object << #LMInvocation
 slots: #(message caller requestId submitted result attempts originalRequestId);
 package: 'Loom-Codex') install.
Smalltalk globals at: #LoomPendingInvocations ifAbsentPut: [ Dictionary new ].
invocation class compile: 'pendingAt: id
 ^ LoomPendingInvocations at: id ifAbsent: [ self error: ''This Loom object invocation is no longer active'' ]'.
invocation compile: 'message: aMessage caller: aContext
 message := aMessage.
 caller := aContext.
 submitted := false'.
invocation compile: 'message ^ message'.
invocation compile: 'caller ^ caller'.
invocation compile: 'attempts ^ attempts ifNil: [ #() ] ifNotNil: [ attempts asArray ]'.
invocation compile: 'recordAttempt: receipt
 attempts ifNil: [
  attempts := OrderedCollection new.
  originalRequestId := receipt at: ''id'' ].
 attempts add: receipt copy'.
invocation compile: 'originalRequestId ^ originalRequestId'.
invocation compile: 'originalRequestId: id originalRequestId := id'.
invocation compile: 'attachTo: id
 requestId := id.
 LoomPendingInvocations at: id put: self'.
invocation compile: 'detach
 requestId ifNotNil: [
  LoomPendingInvocations removeKey: requestId ifAbsent: [ ].
  requestId := nil ]'.
invocation compile: 'evaluate: toolCode sessionId: sessionId returning: returnBlock
 ^ toolCode valueWithArguments: { caller. message. sessionId. returnBlock }'.
invocation compile: 'return: anObject
 requestId ifNil: [ self error: ''This Loom object invocation is no longer active'' ].
 submitted ifTrue: [
  result == anObject ifFalse: [ self error: ''This invocation already has a different return object'' ].
  ^ true ].
 result := anObject.
 submitted := true.
 ^ true'.
invocation compile: 'discardUnsavedResult
 submitted := false.
 result := nil'.
invocation compile: 'result
 submitted ifFalse: [ self error: ''Codex did not return a GT object for '', message selector asString ].
 ^ result'.
#(selector arguments argumentAt: hasResult markedCallerSource prompt evaluate:sessionId:) do: [ :selector |
 (invocation includesSelector: selector) ifTrue: [ invocation removeSelector: selector ] ].
LMCodexClient compile: 'doesNotUnderstand: message
 | original |
 self assertIndependentProcess.
 BlWinitHost uiProcessDo: [ :process |
  process == Processor activeProcess ifTrue: [
   self error: ''Call LoomCodex from an independent GT Process to keep the desktop responsive'' ] ].
 original := LMInvocation new message: message caller: thisContext sender; yourself.
 ^ mutex critical: [
  | outcome receipt |
  [
   outcome := self objectAttempt: original for: original.
   receipt := outcome first.
   [ self shouldContinueAfter: receipt ] whileTrue: [
    outcome := self continue: original after: receipt.
    receipt := outcome first ].
   (receipt at: ''ok'') ifFalse: [ self error: (receipt at: ''error'') ].
   outcome second result
  ] on: Error do: [ :error |
   original originalRequestId ifNotNil: [ :id |
    (Smalltalk globals at: #LoomNativeCodexHost ifAbsent: [ nil ]) ifNotNil: [ :host |
     [ host registry endRecoveryActivity: id because: error messageText ]
      on: Error do: [ :ignored | nil ] ] ].
   error pass ] ]'.
LMCodexClient compile: 'objectAttempt: invocation for: original
 | receipt |
 [
  receipt := self requestReceipt: ''Loom 调用了你。'' action: ''ask'' invocation: invocation.
  original recordAttempt: receipt.
  ^ { receipt. invocation }
 ] ensure: [ invocation detach. activeRequestId := nil ]'.
LMCodexClient compile: 'shouldContinueAfter: receipt
 | host |
 (receipt at: ''needsRecovery'' ifAbsent: [ false ]) ifFalse: [ ^ false ].
 host := Smalltalk globals at: #LoomNativeCodexHost ifAbsent: [ nil ].
 ^ host notNil and: [ host isStopping not ]'.
LMCodexClient compile: 'continue: originalInvocation after: failedAttempt
 "Resume the original Loom invocation. Read the original Message using originalInvocation message. Use its selector and arguments, and inspect originalInvocation caller for the original source and return contract. The second argument is the last failed Codex attempt. originalInvocation attempts has the receipts for all previous attempts. Use their request IDs to check tool results and side effects as necessary. Return the result the original caller expects via loomReturn. This is another attempt within the original business call."
 | retry request |
 request := Message selector: #continue:after: arguments: { originalInvocation. failedAttempt }.
 retry := LMInvocation new message: request caller: thisContext;
  originalRequestId: originalInvocation originalRequestId; yourself.
 ^ self objectAttempt: retry for: originalInvocation'.
'Loom object invocation installed'
