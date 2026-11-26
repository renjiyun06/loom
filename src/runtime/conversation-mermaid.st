"Render closed Mermaid fences outside the GT process and display the result in the native conversation."
| cls |
cls := (Object << #LMChatMermaidRenderer slots: #(lock cache); package: 'Loom-Interface') install.
cls class compile: 'current
 | entry |
 entry := Smalltalk globals at: #LoomChatMermaidRenderer ifAbsent: [ nil ].
 (entry isNil or: [ entry first ~~ Smalltalk session ]) ifTrue: [
  entry := { Smalltalk session. self new }.
  Smalltalk globals at: #LoomChatMermaidRenderer put: entry ].
 ^ entry second'.
cls compile: 'initialize
 super initialize.
 lock := Mutex new.
 cache := LRUCache new computeWeight: [ :value | value first bits byteSize ];
  maximumWeight: 64 * 1024 * 1024; yourself'.
cls compile: 'render: source ifNeeded: required
 ^ lock critical: [
  required value ifFalse: [ ^ nil ].
  cache at: source ifAbsentPut: [ self renderUncached: source ] ]'.
cls compile: 'renderUncached: source
 | node program payload reply image |
 node := ExperimentRoot / ''runtime'' / ''node'' / ''node.exe''.
 program := ExperimentRoot / ''src'' / ''mermaid'' / ''render.mjs''.
 payload := (STONJSON toString: (Dictionary new at: ''source'' put: source; yourself)), String lf.
 reply := STONJSON fromString: (LMPlatformTools run: node arguments: { program fullName }
  input: payload timeout: 35).
 (reply at: ''ok'') ifFalse: [ self error: (reply at: ''error'') ].
 image := ImageReadWriter formFromStream: (ZnBase64Encoder new decode: (reply at: ''png'')) readStream.
 ^ { image. reply at: ''width''. reply at: ''height'' }'.
cls := (BrVerticalPane << #LMChatMermaidBlock slots: #(source fallback state); package: 'Loom-Interface') install.
cls compile: 'source: text fallback: codeBlock
 source := text.
 fallback := codeBlock.
 self hMatchParent; vFitContent.
 self addChild: (self statusLabel: ''正在渲染 Mermaid…'')'.
cls compile: 'statusLabel: text
 ^ BrLabel new aptitude: (BrGlamorousLabelAptitude new fontName: ''Microsoft YaHei UI'';
  fontSize: 12; foreground: (Color gray: 0.46); yourself);
  text: text; yourself'.
cls compile: 'onAddedToSceneGraph
 super onAddedToSceneGraph.
 self startRendering'.
cls compile: 'startRendering
 | renderer |
 state ifNotNil: [ ^ self ].
 state := #rendering.
 renderer := LMChatMermaidRenderer current.
 [ | result message |
  [ result := renderer render: source ifNeeded: [ self isAttachedToSceneGraph ] ]
   on: Error do: [ :error | message := error messageText ].
  self enqueueTask: (BlTaskAction new action: [
   result ifNotNil: [ self showDiagram: result ] ifNil: [
    message ifNotNil: [ self showFailure: message ] ifNil: [
     state := nil.
     self isAttachedToSceneGraph ifTrue: [ self startRendering ] ] ] ])
 ] forkAt: Processor userBackgroundPriority'.
cls compile: 'showDiagram: result
 | image width height |
 width := result second.
 height := result third.
 image := BlSkiaImageElement new image: (SkiaImage fromForm: result first); yourself.
 image constraintsDo: [ :constraints |
  constraints horizontal matchParent.
  constraints vertical exact: height ].
 image when: BlElementExtentChangedEvent do: [
  | scaledHeight |
  image width > 0 ifTrue: [
   scaledHeight := (height * ((image width / width) min: 1)) ceiling.
   scaledHeight = image height ifFalse: [
    image constraintsDo: [ :constraints | constraints vertical exact: scaledHeight ] ] ] ].
 self removeChildren; addChild: image.
 state := #complete.
 fallback := nil'.
cls compile: 'showFailure: message
 state := #complete.
 self removeChildren.
 self addChild: (self statusLabel: ''Mermaid 渲染失败 · '', (message truncateTo: 140)).
 self addChild: fallback value.
 fallback := nil'.
