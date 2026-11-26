"Render closed Mermaid fences outside the GT process and show complete previews with a Windows image-opening action."
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
cls compile: 'imageFileFor: form
 | bytes folder target temporary |
 bytes := ByteArray streamContents: [ :stream | PNGReadWriter putForm: form onStream: stream ].
 folder := ExperimentRoot / ''state'' / ''conversation'' / ''mermaid-images''.
 folder ensureCreateDirectory.
 target := folder / (''Mermaid-'', (SHA256 hashMessage: bytes) hex, ''.png'').
 target isFile ifTrue: [ ^ target ].
 temporary := folder / (UUID new asString, ''.tmp'').
 [ temporary binaryWriteStreamDo: [ :out | out nextPutAll: bytes ].
   ((LMPlatformTools move: temporary to: target) = 0 and: [ target isFile not ])
    ifTrue: [ self error: ''无法保存 Mermaid 图片'' ]
 ] ensure: [ temporary ensureDelete ].
 ^ target'.

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
 self removeChildren; addChild: (self previewFor: result).
 state := #complete.
 fallback := nil'.
cls compile: 'previewFor: result
 | card toolbar imageRow image openButton notice size preferredWidth lastWidth resize |
 size := result second @ result third.
 preferredWidth := ((size x * ((160 / size y) min: 1)) ceiling max: 112) min: 360.
 card := BrVerticalPane new id: #loomMermaidPreview; vFitContent;
  background: Color white; border: (BlBorder paint: (Color gray: 0.88) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 6); yourself.
 toolbar := BrHorizontalPane new id: #loomMermaidPreviewToolbar; hMatchParent; vExact: 28;
  padding: (BlInsets left: 2 right: 2); alignCenterRight; yourself.
 image := BlSkiaImageElement new id: #loomMermaidThumbnail;
  image: (SkiaImage fromForm: result first); yourself.
 imageRow := BrHorizontalPane new hMatchParent; vFitContent; alignCenter; addChild: image; yourself.
 notice := (self statusLabel: '''') visibility: BlVisibility gone; yourself.
 openButton := (Smalltalk globals at: #LMChatStyle)
  replyAction: #loomMermaidOpenImage icon: ''external-link''
  action: [ self openImage: result first with: openButton notice: notice ].
 openButton label: ''用默认图片应用打开''; mouseCursor: BlHandCursor new.
 openButton addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [
  self statusLabel: ''用默认图片应用打开'' ]).
 toolbar addChild: openButton.
 card addChildren: { toolbar. imageRow. notice }.
 resize := [ | width scale scaled |
  width := self width > 0 ifTrue: [ self width min: preferredWidth ] ifFalse: [ preferredWidth ].
  width = lastWidth ifFalse: [
   lastWidth := width.
   scale := (1 min: (width / size x)) min: (160 / size y).
   scaled := (size * scale) floor.
   card hExact: width.
   image size: ((scaled x max: 1) @ (scaled y max: 1)) ] ].
 self when: BlElementExtentChangedEvent do: [ resize value ].
 resize value.
 ^ card'.
cls compile: 'openImage: form with: button notice: notice
 button enabled: false.
 notice visibility: BlVisibility gone.
 [ | failure |
  [ | file |
   file := LMChatMermaidRenderer current imageFileFor: form.
   LMPlatformTools openWithDefaultApplication: file
  ] on: Error do: [ :error | failure := error messageText ].
  self enqueueTask: (BlTaskAction new action: [
   button enabled: true.
   failure ifNotNil: [
    notice text: ''无法打开图片 · '', (failure truncateTo: 140); visibility: BlVisibility visible ] ])
 ] forkAt: Processor userBackgroundPriority'.

cls compile: 'showFailure: message
 state := #complete.
 self removeChildren.
 self addChild: (self statusLabel: ''Mermaid 渲染失败 · '', (message truncateTo: 140)).
 self addChild: fallback value.
 fallback := nil'.
