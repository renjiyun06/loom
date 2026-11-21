"Temporary diagnostic editor; never modifies or submits the conversation draft."
Smalltalk globals at: #LoomImeBefore put: (Dictionary new
 at: 'draft' put: (LoomConversationWindow instVarNamed: 'input') text asString copy;
 at: 'thread' put: LoomCodex threadId;
 at: 'messages' put: LoomConversation records size; yourself).
(BlParallelUniverse forHost: BlWinitHost) defer: [
 | testSpace editor |
 testSpace := BlSpace new title: '输入检查'.
 editor := LoomConversationWindow editor beEditable; matchParent; text: '中文ABC'; yourself.
 testSpace root addChild: editor.
 Smalltalk globals at: #LoomImeTestSpace put: testSpace.
 Smalltalk globals at: #LoomImeTestEditor put: editor.
 LoomConversationWindow hostWorld showSpace: testSpace ].
true
