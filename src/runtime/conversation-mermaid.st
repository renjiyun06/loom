"Render closed Mermaid fences outside the GT process and open diagrams in a native GT viewer."
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
cls := (BrVerticalPane << #LMChatMermaidViewer slots: #(form image viewport extent zoom fitWidth percentage imageSession); package: 'Loom-Interface') install.
cls compile: 'diagram: result
 | toolbar |
 form := result first.
 extent := result second @ result third.
 image := BlSkiaImageElement new.
 fitWidth := true.
 viewport := BrScrollPane new aptitude: BrScrollPaneAptitude new
  + BrGlamorousWithVerticalScrollbarAptitude new + BrGlamorousWithHorizontalScrollbarAptitude new;
  content: image; yourself.
 viewport when: BlElementExtentChangedEvent do: [ fitWidth ifTrue: [ self fitToWidth ] ].
 percentage := BrLabel new aptitude: (BrGlamorousLabelAptitude new fontName: ''Segoe UI'';
  fontSize: 12; yourself); yourself.
 toolbar := BrHorizontalPane new hMatchParent; vFitContent; alignCenterLeft;
  padding: (BlInsets top: 6 left: 8 bottom: 6 right: 8); yourself.
 toolbar layout cellSpacing: 8.
 toolbar addChildren: {
  self zoomButton: ''−'' action: [ self zoomBy: 0.8 ].
  percentage.
  self zoomButton: ''+'' action: [ self zoomBy: 1.25 ].
  self zoomButton: ''适合宽度'' action: [ self fitToWidth ] }.
 self matchParent; padding: (BlInsets all: 8).
 self applyZoom: 1.
 self addChildren: { toolbar. viewport }'.
cls compile: 'onAddedToSceneGraph
 super onAddedToSceneGraph.
 imageSession == Smalltalk session ifTrue: [ ^ self ].
 image image: (SkiaImage fromForm: form).
 image invalidate.
 imageSession := Smalltalk session'.
cls compile: 'zoomButton: title action: action
 ^ BrButton new aptitude: (BrGlamorousButtonWithLabelAptitude new fontName: ''Microsoft YaHei UI'';
  fontSize: 12; yourself); label: title; action: action; yourself'.
cls compile: 'fitToWidth
 | available |
 fitWidth := true.
 available := viewport width - 16.
 available > 0 ifTrue: [ self applyZoom: ((available / extent x) min: 1) ]'.
cls compile: 'zoomBy: multiplier
 fitWidth := false.
 self applyZoom: (((zoom * multiplier) max: 0.1) min: 4)'.
cls compile: 'applyZoom: scale
 zoom = scale ifTrue: [ ^ self ].
 zoom := scale.
 image size: (extent * zoom) ceiling.
 percentage text: (zoom * 100) rounded asString, ''%'''.
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
 | card preview image caption size preferredWidth lastWidth resize |
 size := result second @ result third.
 preferredWidth := (size x max: 140) min: 360.
 image := BlSkiaImageElement new image: (SkiaImage fromForm: result first); yourself.
 preview := BlElement new layout: BlBasicLayout new; clipChildren: true;
  background: Color white; yourself.
 preview addChild: image.
 caption := (self statusLabel: ''查看完整图'') margin: (BlInsets top: 5 bottom: 5); yourself.
 card := BrButton new id: #loomMermaidPreview; aptitude: BrGlamorousButtonLayoutAptitude new;
  label: ''查看完整图''; beFocusable; vFitContent;
  layout: (BlLinearLayout vertical horizontalAlignment: BlElementAlignment horizontal center);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 6); clipChildren: true;
  mouseCursor: BlHandCursor new;
  action: [ self openDiagram: result from: card ]; yourself.
 card addAptitude: (BrStyleCommonAptitude new
  default: [ :style | style background: (Color gray: 0.965); border: (BlBorder paint: (Color gray: 0.88) width: 1) ];
  hovered: [ :style | style background: (Color gray: 0.93) ];
  focused: [ :style | style border: (BlBorder paint: (Color gray: 0.55) width: 1) ]).
 card addChildren: { preview. caption }.
 resize := [ | width imageWidth imageHeight |
  width := self width > 0 ifTrue: [ self width min: preferredWidth ] ifFalse: [ preferredWidth ].
  width = lastWidth ifFalse: [
   lastWidth := width.
   imageWidth := size x min: width.
   imageHeight := (size y * (imageWidth / size x)) ceiling.
   card hExact: width.
   preview size: width @ (imageHeight min: 160).
   image size: imageWidth @ imageHeight; relocate: ((width - imageWidth) / 2) @ 0 ] ].
 self when: BlElementExtentChangedEvent do: [ resize value ].
 resize value.
 ^ card'.
cls compile: 'openDiagram: result from: card
 | world viewer tab token |
 world := self space.
 token := card userData at: #loomMermaidViewerToken ifAbsentPut: [ Object new ].
 (world isKindOf: GtWorld) ifTrue: [
  tab := world tabGroup tabs detect: [ :each | (each model isKindOf: BlSpace) and: [
   (each model root userData at: #loomMermaidViewerToken ifAbsent: [ nil ]) == token ] ]
   ifNone: [ nil ].
  tab ifNotNil: [ tab select. ^ self ] ].
 viewer := BlSpace new title: ''Mermaid 图''; extent: 1000 @ 740; yourself.
 viewer root userData at: #loomMermaidViewerToken put: token.
 viewer root addChild: (LMChatMermaidViewer new diagram: result; yourself).
 (world isKindOf: GtWorld) ifTrue: [ world showSpace: viewer ] ifFalse: [ self showSpace: viewer ]'.
cls compile: 'showFailure: message
 state := #complete.
 self removeChildren.
 self addChild: (self statusLabel: ''Mermaid 渲染失败 · '', (message truncateTo: 140)).
 self addChild: fallback value.
 fallback := nil'.
