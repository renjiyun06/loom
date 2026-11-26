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
 cache := LRUCache new computeWeight: [ :value | self cacheWeightOf: value ];
  maximumWeight: self maximumCacheWeight; yourself'.
cls compile: 'maximumCacheWeight ^ 64 * 1024 * 1024'.
cls compile: 'cacheWeightOf: result
 ^ result first bits byteSize + result fourth value size'.
cls compile: 'render: source ifNeeded: required
 | result |
 ^ lock critical: [
  required value ifFalse: [ ^ nil ].
  (cache includesKey: source) ifTrue: [ ^ cache at: source ].
  result := self renderUncached: source.
  (self cacheWeightOf: result) < self maximumCacheWeight ifTrue: [ cache at: source put: result ].
  result ]'.
cls compile: 'renderUncached: source
 | node program payload reply image bytes |
 node := ExperimentRoot / ''runtime'' / ''node'' / ''node.exe''.
 program := ExperimentRoot / ''src'' / ''mermaid'' / ''render.mjs''.
 payload := (STONJSON toString: (Dictionary new at: ''source'' put: source; yourself)), String lf.
 reply := STONJSON fromString: (LMPlatformTools run: node arguments: { program fullName }
  input: payload timeout: 35).
 (reply at: ''ok'') ifFalse: [ self error: (reply at: ''error'') ].
 bytes := ZnBase64Encoder new decode: (reply at: ''png'').
 image := ImageReadWriter formFromStream: bytes readStream.
 ^ { image. reply at: ''width''. reply at: ''height''. (reply at: ''sha256'') -> bytes }'.
cls compile: 'imageFileForPng: png
 | folder target temporary |
 folder := ExperimentRoot / ''state'' / ''conversation'' / ''mermaid-images''.
 folder ensureCreateDirectory.
 target := folder / (''Mermaid-'', png key, ''.png'').
 target isFile ifTrue: [ ^ target ].
 temporary := folder / (UUID new asString, ''.tmp'').
 [ temporary binaryWriteStreamDo: [ :out | out nextPutAll: png value ].
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
 | notice |
 "A reply already rendering during a live reload may have the old result shape."
 result size = 3 ifTrue: [ state := nil. self startRendering. ^ self ].
 notice := (self statusLabel: '''') id: #loomMermaidOpenStatus; visibility: BlVisibility gone; yourself.
 self removeChildren; addChildren: { self previewFor: result notice: notice. notice }.
 state := #complete.
 fallback := nil'.
cls compile: 'previewFor: result notice: notice
 | card toolbar imageRow image openButton size png preferredWidth lastWidth resize |
 size := result second @ result third.
 png := result fourth.
 preferredWidth := ((size x * ((160 / size y) min: 1)) ceiling max: 112) min: 360.
 card := BrVerticalPane new id: #loomMermaidPreview; vFitContent;
  background: Color white; border: (BlBorder paint: (Color gray: 0.88) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 6); yourself.
 toolbar := BrHorizontalPane new id: #loomMermaidPreviewToolbar; hMatchParent; vExact: 28;
  padding: (BlInsets left: 2 right: 2); alignCenterRight; yourself.
 image := BlSkiaImageElement new id: #loomMermaidThumbnail;
  image: (SkiaImage fromForm: result first); yourself.
 imageRow := BrHorizontalPane new hMatchParent; vFitContent; alignCenter; addChild: image; yourself.
 openButton := (Smalltalk globals at: #LMChatStyle)
  replyAction: #loomMermaidOpenImage icon: ''external-link''
  action: [ self openPng: png with: openButton notice: notice ].
 openButton label: ''用默认图片应用打开''; mouseCursor: BlHandCursor new.
 openButton addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [
  self statusLabel: ''用默认图片应用打开'' ]).
 toolbar addChild: openButton.
 card addChildren: { toolbar. imageRow }.
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
cls compile: 'openPng: png with: button notice: notice
 | cached owner |
 cached := button userData at: #loomMermaidImageFile ifAbsent: [ nil ].
 owner := 0.
 self spaceDo: [ :space | (space host isKindOf: BlWinitHost) ifTrue: [
  space hostSpaceDo: [ :host | owner := host window hwnd asInteger ] ] ].
 button enabled: false.
 notice text: ''正在打开图片…''; visibility: BlVisibility visible.
 [ | file failure |
  [ file := (cached notNil and: [ cached isFile ])
    ifTrue: [ cached ] ifFalse: [ LMChatMermaidRenderer current imageFileForPng: png ].
   LMPlatformTools openWithDefaultApplication: file owner: owner
  ] on: Error do: [ :error | failure := error messageText ].
  self enqueueTask: (BlTaskAction new action: [
   file ifNotNil: [ button userData at: #loomMermaidImageFile put: file ].
   button enabled: true.
   notice text: (failure ifNil: [ ''已交给 Windows 默认图片应用'' ]
    ifNotNil: [ ''无法打开图片 · '', (failure truncateTo: 140) ]) ])
 ] forkAt: Processor userBackgroundPriority'.

cls compile: 'showFailure: message
 state := #complete.
 self removeChildren.
 self addChild: (self statusLabel: ''Mermaid 渲染失败 · '', (message truncateTo: 140)).
 self addChild: fallback value.
 fallback := nil'.
