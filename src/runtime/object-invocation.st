"An intercepted Smalltalk send. The arguments and result stay in this image."
| invocation |
invocation := (Object << #LMInvocation
 slots: #(message caller requestId submitted result attempts originalRequestId replacesRequestId);
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
invocation compile: 'activities
 "The activity registry. Scope the history by the request IDs in attempts."
 ^ (Smalltalk globals at: #LoomNativeCodexHost) registry'.
invocation compile: 'recordAttempt: receipt
 attempts ifNil: [
  attempts := OrderedCollection new.
  originalRequestId := receipt at: ''id'' ].
 attempts add: receipt copy'.
invocation compile: 'originalRequestId ^ originalRequestId'.
invocation compile: 'originalRequestId: id originalRequestId := id'.
invocation compile: 'replacesRequestId ^ replacesRequestId'.
invocation compile: 'replacesRequestId: id replacesRequestId := id'.
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
    outcome := self recover: original after: receipt.
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
LMCodexClient compile: 'recover: originalInvocation after: failedAttempt
 "恢复原来尚未完成的 Loom 调用。两个实参分别是原调用和最近一轮的回执。回执的 replaceCodexSession 表示本轮使用新开的 Codex 会话。按以下顺序恢复现场。

  1. 从 originalInvocation message 读取原始消息的选择器和实参，从 originalInvocation caller 查看业务入口、源代码及返回约定。三个回复入口的上下文以 source 和 messageId 标识原始消息。
  2. 从 originalInvocation activities 取得活动记录对象，用 failedAttempt 的 id 查上一轮已发生的工具调用和结果。originalInvocation attempts 包含各轮回执。活动对象的 databaseFile 可用于按这些请求 ID 做自定义只读查询。涉及发送或写入而结果不明的操作先查业务状态，再决定是否重试。
  3. 需要补充前文时，沿用原调用上下文的邮件、微信和桌面对话对象。升级前已发出的调用可能仍带旧的字典，按当时的实参查阅。

  继续处理原任务，通过 loomReturn 交回原业务调用所需的对象。"
 | retry request |
 request := Message selector: #recover:after: arguments: { originalInvocation. failedAttempt }.
 retry := LMInvocation new message: request caller: thisContext;
  originalRequestId: originalInvocation originalRequestId; yourself.
 (failedAttempt at: ''replaceCodexSession'' ifAbsent: [ false ]) ifTrue: [
  retry replacesRequestId: (failedAttempt at: ''id'') ].
 ^ self objectAttempt: retry for: originalInvocation'.
"An invocation stack from before this update can still send the previous selector."
LMCodexClient compile: 'continue: originalInvocation after: failedAttempt
 ^ self recover: originalInvocation after: failedAttempt'.
'Loom object invocation installed'
