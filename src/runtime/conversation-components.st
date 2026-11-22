"Native read-only Markdown, message rows and compact activity details."
| cls |
Smalltalk globals at: #LMIcons ifAbsent: [
 Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'icons.st') contents ].
cls := (Object << #LMChatStyle slots: #(); package: 'Loom-Interface') install.
cls class compile: 'syncActivities: list collection: current with: incoming
 | source index changed previous next |
 source := (list childNamed: #scrollable) dataSource.
 index := 1.
 changed := false.
 [ index <= current size and: [ index <= incoming size ] ] whileTrue: [
  previous := current at: index.
  next := incoming at: index.
  previous == next ifTrue: [ index := index + 1 ] ifFalse: [
   (previous at: ''seq'') = (next at: ''seq'') ifTrue: [
    current at: index put: next.
    source notifyItemsChanged: (index to: index).
    index := index + 1 ] ifFalse: [
    (previous at: ''seq'') < (next at: ''seq'') ifTrue: [
     current removeAt: index.
     source notifyItemsRemoved: (index to: index) ] ifFalse: [
     current add: next beforeIndex: index.
     source notifyItemsInserted: (index to: index).
     index := index + 1 ] ].
   changed := true ] ].
 index <= incoming size ifTrue: [
  current addAll: (incoming allButFirst: index - 1).
  source notifyItemsInserted: (index to: incoming size).
  ^ true ].
 index <= current size ifTrue: [
  previous := current size.
  [ current size >= index ] whileTrue: [ current removeLast ].
  source notifyItemsRemoved: (index to: previous).
  ^ true ].
 ^ changed'.
cls class compile: 'attachmentIconForImage: isImage size: size
 | name |
 name := isImage ifTrue: [ ''image'' ] ifFalse: [ ''file'' ].
 ^ (LMIcons iconNamed: name size: size color: (Color gray: 0.40))
  id: (isImage ifTrue: [ #loomImageAttachmentIcon ] ifFalse: [ #loomFileAttachmentIcon ]); yourself'.
cls class compile: 'attachmentSurfaceAptitude
 ^ BrStyleCommonAptitude new default: [ :style |
  style background: (Color gray: 0.965);
   border: (BlBorder paint: (Color gray: 0.9) width: 1);
   geometry: (BlRoundedRectangleGeometry cornerRadius: 7) ]; yourself'.
cls class compile: 'button: title action: block
 ^ self button: title action: block foreground: (Color gray: 0.3) background: Color white'.
cls class compile: 'button: title action: block foreground: foreground background: background
 | apt label button hoverBackground |
 apt := BrGlamorousButtonWithLabelAptitude new.
 label := apt instVarNamed: ''labelAptitude''.
 label defaultColor: foreground; hoveredColor: foreground; pressedColor: foreground; selectedColor: foreground.
 apt := apt - BrGlamorousButtonExteriorAptitude.
 apt fontName: ''Microsoft YaHei UI''; fontSize: 13.
 button := BrButton new aptitude: apt; label: title; action: block;
  vExact: 26; padding: (BlInsets left: 8 right: 8); background: background;
  border: (BlBorder paint: (Color gray: 0.88) width: 0); yourself.
 hoverBackground := background alpha = 0
  ifTrue: [ Color gray: 0.955 ]
  ifFalse: [ background brightness > 0.5
   ifTrue: [ Color gray: background brightness - 0.045 ] ifFalse: [ Color gray: 0.25 ] ].
 button addAptitude: (BrStyleCommonAptitude new
  default: [ :style | style background: background ];
  hovered: [ :style | style background: hoverBackground ];
  focused: [ :style | style border: (BlBorder paint: (Color gray: 0.55) width: 1) ]).
 ^ button'.
cls class compile: 'chevron: expanded
 ^ LMIcons iconNamed: (expanded ifTrue: [ ''chevron-down'' ] ifFalse: [ ''chevron-right'' ])
  size: 14 color: (Color gray: 0.48)'.
cls class compile: 'codePanel: code language: language
 | pane header body width text |
 pane := BrVerticalPane new hMatchParent; vFitContent;
  background: (Color gray: 0.975); border: (BlBorder paint: (Color gray: 0.88) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 4); yourself.
 header := BrHorizontalPane new hMatchParent; vExact: 30; alignCenterLeft;
  padding: (BlInsets left: 11 right: 8); background: (Color gray: 0.945); yourself.
 header addChild: ((self label: (language ifEmpty: [ ''text'' ]) size: 12) hMatchParent; yourself).
 header addChild: (self flatButton: ''复制代码'' action: [ GtClipboard clipboardText: code ]).
 text := code asRopedText fontName: ''Consolas''; fontSize: 13; yourself.
 body := self readOnly: text size: 13.
 body aptitude fontName: ''Consolas''.
 body padding: (BlInsets top: 10 right: 13 bottom: 10 left: 13).
 width := 28 + (code lines inject: 0 into: [ :longest :line |
  longest max: (line inject: 0 into: [ :sum :char | sum + (char = Character tab
   ifTrue: [ 16 ] ifFalse: [ char asInteger > 127 ifTrue: [ 14 ] ifFalse: [ 8 ] ]) ]) ]).
 pane addChildren: { header. self horizontalViewportFor: body minimumWidth: width }.
 ^ pane'.
cls class compile: 'editor: size
 ^ BrEditor new
  aptitude: (BrGlamorousEditorAptitude new fontName: ''Microsoft YaHei UI''; fontSize: size; yourself);
  hMatchParent; yourself'.
cls class compile: 'flatButton: title action: block
 | button |
 button := self button: title action: block foreground: (Color gray: 0.3) background: Color transparent.
 button addAptitude: (BrStyleCommonAptitude new
  hovered: [ :style | style background: (Color gray: 0.95) ];
  pressed: [ :style | style background: (Color gray: 0.92) ]).
 ^ button'.
cls class compile: 'formattedText: value size: size
 | text inset |
 text := value asRopedText copy.
 value isString ifTrue: [ text fontName: ''Microsoft YaHei UI''; fontSize: size ].
 inset := size >= 14 ifTrue: [ 3.5 ] ifFalse: [ 2.5 ].
 text lineSpacing: inset * 2; paragraphMargin: (BlInsets top: inset bottom: inset).
 ^ text'.
cls class compile: 'grey: value ^ Color gray: value'.
cls class compile: 'horizontalViewportFor: content minimumWidth: minimum
 | viewport resize |
 viewport := BrScrollPane new
  aptitude: BrScrollPaneAptitude new + BrGlamorousWithHorizontalScrollbarAptitude new;
  hMatchParent; vFitContent; content: content; yourself.
 resize := [ | width |
  width := minimum max: viewport width.
  (content width - width) abs > 0.5 ifTrue: [ content hExact: width ] ].
 content hExact: minimum.
 viewport addEventHandlerOn: BlElementExtentChangedEvent do: [ :event | resize value ].
 ^ viewport'.
cls class compile: 'jumpButton: block
 ^ (self button: ''有新内容 · 回到最新'' action: block)
  geometry: (BlRoundedRectangleGeometry cornerRadius: 14);
  border: (BlBorder paint: (Color gray: 0.86) width: 1); yourself'.
cls class compile: 'measureLabel: text size: size
 | label |
 label := self label: text size: size.
 label forceLayout.
 ^ label width'.
cls class compile: 'readingInsetFor: contentWidth viewport: viewportWidth padding: wide medium: medium narrow: narrow
 | maximum gutter |
 maximum := viewportWidth >= 1600 ifTrue: [ 1160 ] ifFalse: [ 1080 ].
 gutter := viewportWidth <= 800 ifTrue: [ narrow ] ifFalse: [ viewportWidth <= 1100 ifTrue: [ medium ] ifFalse: [ wide ] ].
 ^ ((contentWidth - maximum) max: 0) / 2 + gutter'.
cls class compile: 'ellipsize: text at: width size: size
 | low high middle suffix |
 width <= 0 ifTrue: [ ^ text ].
 (self measureLabel: text size: size) <= width ifTrue: [ ^ text ].
 suffix := ''…''. low := 0. high := text size.
 [ low < high ] whileTrue: [
  middle := (low + high + 1) // 2.
  (self measureLabel: (text first: middle), suffix size: size) <= width
   ifTrue: [ low := middle ] ifFalse: [ high := middle - 1 ] ].
 ^ (text first: low), suffix'.
cls class compile: 'iconButton: stencil title: title action: block
 | icon |
 icon := stencil asElement.
 icon withAllChildrenBreadthFirstDo: [ :element |
  (element geometry isKindOf: BlSvgPath) ifTrue: [ element background: (Color gray: 0.45) ] ].
 ^ self iconElementButton: icon title: title action: block'.
cls class compile: 'iconElementButton: icon title: title action: block
 | button |
 button := self button: '''' action: block foreground: (Color gray: 0.3) background: Color transparent.
 button hExact: 27; vExact: 26; padding: (BlInsets all: 4).
 button addChild: icon.
 button addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [ self label: title size: 12 ]).
 ^ button'.
cls class compile: 'inlineText: source
 | out spans text |
 out := String new writeStream. spans := OrderedCollection new.
 self parseInline: source into: out spans: spans.
 text := out contents asRopedText.
 text fontName: ''Microsoft YaHei UI''; fontSize: 14; foreground: (Color gray: 0.16).
 spans do: [ :span | | part |
  span second <= span third ifTrue: [
   part := text from: span second to: span third.
   span first = #bold ifTrue: [ part bold ].
   span first = #italic ifTrue: [ part italic ].
   span first = #code ifTrue: [ part fontName: ''Consolas''; fontSize: 13;
    background: (Color gray: 0.95); foreground: (Color gray: 0.25) ].
   span first = #link ifTrue: [
    part foreground: (Color gray: 0.25); underline.
    ((span fourth beginsWith: ''https://'') or: [
     (span fourth beginsWith: ''http://'') or: [
      (span fourth beginsWith: ''mailto:'') or: [ (span fourth beginsWith: ''file:///'') or: [ span fourth size > 2 and: [ (span fourth at: 2) = $: and: [ span fourth first isLetter ] ] ] ] ] ])
     ifTrue: [
      part attribute: (BrTextClickAttribute new action: [
       | target |
       target := span fourth.
       ((target size > 2) and: [ (target at: 2) = $: ]) ifTrue: [ target := ''file:///'', target ].
       WebBrowser openOn: target ]; yourself) ] ] ] ].
 ^ text'.
cls class compile: 'label: text size: size
 ^ BrLabel new aptitude: (BrGlamorousLabelAptitude new fontName: ''Microsoft YaHei UI'';
  fontSize: size; foreground: (Color gray: (size <= 12 ifTrue: [ 0.52 ] ifFalse: [ 0.2 ])); yourself);
  text: text; yourself'.
cls class compile: 'moreButton: block
 | text button |
 text := ''...'' asRopedText fontName: ''Segoe UI''; fontSize: 15; yourself.
 button := self flatButton: text action: block.
 button hExact: 28; vExact: 28; padding: (BlInsets all: 2).
 button addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [ self label: ''更多'' size: 12 ]).
 ^ button'.
cls class compile: 'parseInline: source into: out spans: spans
 | i size token end start close url marker |
 i := 1. size := source size.
 [ i <= size ] whileTrue: [
  marker := nil.
  (i < size and: [ (source copyFrom: i to: i + 1) = ''**'' ])
   ifTrue: [ marker := ''**'' ]
   ifFalse: [
    (source at: i) = (Character value: 96) ifTrue: [ marker := String with: (Character value: 96) ].
    (source at: i) = $* ifTrue: [ marker := ''*'' ] ].
  marker ifNotNil: [
   end := source findString: marker startingAt: i + marker size.
   end > (i + marker size) ifTrue: [
    start := out position + 1. token := source copyFrom: i + marker size to: end - 1.
    marker first = (Character value: 96)
     ifTrue: [ out nextPutAll: token ]
     ifFalse: [ self parseInline: token into: out spans: spans ].
    spans add: { (marker = ''**'' ifTrue: [ #bold ] ifFalse: [
     marker = ''*'' ifTrue: [ #italic ] ifFalse: [ #code ] ]). start. out position. nil }.
    i := end + marker size.
    marker := #handled ] ].
  marker = #handled ifFalse: [
   close := 0. end := 0.
   (source at: i) = $[ ifTrue: [
    close := source findString: '']('' startingAt: i + 1.
    close > 0 ifTrue: [ end := source findString: '')'' startingAt: close + 2 ] ].
   (close > 0 and: [ end > (close + 2) ])
    ifTrue: [
     start := out position + 1.
     self parseInline: (source copyFrom: i + 1 to: close - 1) into: out spans: spans.
     url := source copyFrom: close + 2 to: end - 1.
     spans add: { #link. start. out position. url }.
     i := end + 1 ]
    ifFalse: [ out nextPut: (source at: i). i := i + 1 ] ] ]'.
cls class compile: 'readOnly: text size: size
 ^ (self editor: size) beReadOnlyWithSelection; vFitContent;
  padding: (BlInsets all: 0); margin: (BlInsets all: 0);
  text: (self formattedText: text size: size); yourself'.
cls class compile: 'replyAction: name icon: iconName action: block
 | icon |
 icon := LMIcons iconNamed: iconName.
 icon constraintsDo: [ :c | c frame horizontal alignCenter. c frame vertical alignCenter ].
 ^ BrButton new id: name;
  layout: BlFrameLayout new; hExact: 26; vExact: 24; beFocusable;
  geometry: (BlRoundedRectangleGeometry cornerRadius: 4);
  addChild: icon;
  addAptitude: (BrStyleCommonAptitude new
   hovered: [ :style | style background: (Color gray: 0.95) ];
   pressed: [ :style | style background: (Color gray: 0.92) ];
   focused: [ :style | style border: (BlBorder paint: (Color gray: 0.55) width: 1) ]);
  action: block; yourself'.
cls class compile: 'table: spec
 | pane rows widths |
 pane := BrVerticalPane new hMatchParent; vFitContent;
  border: (BlBorder paint: (Color gray: 0.89) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 4); yourself.
 rows := { spec second } , spec third.
 widths := (1 to: spec second size) collect: [ :index |
  | natural |
  natural := rows inject: 100 into: [ :widest :cells |
   widest max: (20 + (self measureLabel: (self inlineText: (cells at: index ifAbsent: [ '''' ])) asString size: 13)) ].
  natural min: 320 ].
 rows withIndexDo: [ :cells :rowIndex | | row |
  row := BrHorizontalPane new hMatchParent; vFitContent;
   background: (rowIndex = 1 ifTrue: [ Color gray: 0.965 ] ifFalse: [ Color white ]);
   border: (BlBorder paint: (Color gray: 0.92) width: 1); yourself.
  1 to: spec second size do: [ :index | | content cell |
   content := self inlineText: (cells at: index ifAbsent: [ '''' ]).
   content fontSize: 13.
   rowIndex = 1 ifTrue: [ content bold ].
   cell := self readOnly: content size: 13.
   cell padding: (BlInsets top: 6 right: 9 bottom: 6 left: 9).
   cell constraintsDo: [ :c | c linear weight: (widths at: index) ].
   row addChild: cell ].
  pane addChild: row ].
 ^ self horizontalViewportFor: pane minimumWidth: widths sum'.
cls class compile: 'tableCells: line
 | trimmed result cell escaped code |
 trimmed := line trimBoth.
 (trimmed beginsWith: ''|'') ifTrue: [ trimmed := trimmed allButFirst ].
 (trimmed endsWith: ''|'') ifTrue: [ trimmed := trimmed allButLast ].
 result := OrderedCollection new. cell := String new writeStream.
 escaped := false. code := false.
 trimmed do: [ :char |
  escaped
   ifTrue: [
    ((char = $|) or: [ (char = (Character value: 96)) or: [ char = (Character value: 92) ] ])
     ifFalse: [ cell nextPut: (Character value: 92) ].
    cell nextPut: char. escaped := false ]
   ifFalse: [
    char = (Character value: 92)
     ifTrue: [ code ifTrue: [ cell nextPut: char ] ifFalse: [ escaped := true ] ]
     ifFalse: [
      char = (Character value: 96) ifTrue: [ code := code not ].
      (char = $| and: [ code not ])
       ifTrue: [ result add: cell contents trimBoth. cell := String new writeStream ]
       ifFalse: [ cell nextPut: char ] ] ] ].
 escaped ifTrue: [ cell nextPut: (Character value: 92) ].
 result add: cell contents trimBoth.
 ^ result asArray'.
cls := (BrVerticalPane << #LMMarkdownView slots: #(#source #specs #views); package: 'Loom-Interface') install.
cls compile: 'blockView: spec
 | kind text editor row bar |
 kind := spec first.
 kind = #code ifTrue: [ ^ (LMChatStyle codePanel: spec third language: spec second)
  margin: (BlInsets top: 8 bottom: 8); yourself ].
 kind = #table ifTrue: [ ^ (LMChatStyle table: spec)
  margin: (BlInsets top: 8 bottom: 8); yourself ].
 kind = #rule ifTrue: [ ^ BrHorizontalPane new hMatchParent; vExact: 1; background: (Color gray: 0.9); yourself ].
 text := LMChatStyle inlineText: (kind = #heading ifTrue: [ spec third ] ifFalse: [
  kind = #list ifTrue: [ spec third ] ifFalse: [ spec second ] ]).
 kind = #heading ifTrue: [
  text bold; fontSize: (spec second = 1 ifTrue: [ 18 ] ifFalse: [ spec second = 2 ifTrue: [ 16 ] ifFalse: [ 14 ] ]) ].
 editor := LMChatStyle readOnly: text size: 14.
 kind = #heading ifTrue: [
  editor aptitude fontSize: (spec second = 1 ifTrue: [ 18 ] ifFalse: [ spec second = 2 ifTrue: [ 16 ] ifFalse: [ 14 ] ]).
  editor margin: (BlInsets top: 15 bottom: 5) ].
 kind = #list ifTrue: [
  row := BrHorizontalPane new hMatchParent; vFitContent; yourself.
  row addChild: ((LMChatStyle label: spec second size: 14) hExact: 22; yourself).
  row addChild: editor. ^ row ].
 kind = #quote ifTrue: [
  row := BrHorizontalPane new hMatchParent; vFitContent;
   padding: (BlInsets all: 7); background: (Color gray: 0.975); yourself.
  editor margin: (BlInsets left: 8).
  bar := BrHorizontalPane new hExact: 2; vMatchParent; background: (Color gray: 0.65); yourself.
  row addChildren: { bar. editor }. ^ row ].
 ^ editor'.
cls compile: 'initialize
 super initialize.
 self hMatchParent; vFitContent.
 self layout cellSpacing: 2.
 specs := #(). views := OrderedCollection new.
 self enableReplySelection'.
cls compile: 'enableReplySelection
 (self userData at: #replySelectionEnabled ifAbsent: [ false ]) ifTrue: [ ^ self ].
 self userData at: #replySelectionEnabled put: true.
 self addEventFilterOn: BlMouseDownEvent do: [ :event | self beginReplySelection: event ].
 self addEventFilterOn: BlDragEvent do: [ :event | self extendReplySelection: event ].
 self addEventFilterOn: BlDragEndEvent do: [ :event | self userData removeKey: #replySelectionAnchor ifAbsent: [ ] ].
 self addEventFilterOn: BlKeyDownEvent do: [ :event |
  (event key = BlKeyboardKey c and: [ event modifiers isPrimaryModifier ]) ifTrue: [
   self copyReplySelection ifTrue: [ event consumed: true ] ] ]'.
cls compile: 'beginReplySelection: event
 | target index |
 event primaryButtonPressed ifFalse: [ ^ self ].
 self clearReplySelection.
 target := event target withAllParentsDetect: [ :element | element isKindOf: BrEditor ]
  ifFound: #yourself ifNone: [ ^ self ].
 index := self replyTextIndexAt: event position in: target.
 index ifNotNil: [ self userData at: #replySelectionAnchor put: target -> index ]'.
cls compile: 'clearReplySelection
 | editors |
 self userData removeKey: #replySelectionAnchor ifAbsent: [ ].
 editors := self userData removeKey: #replySelectedEditors ifAbsent: [ #() ].
 editors do: [ :element | element editor deselectAll ]'.
cls compile: 'extendReplySelection: event
 | anchor editors origin destination index first last from to previous selected |
 anchor := self userData at: #replySelectionAnchor ifAbsent: [ ^ self ].
 editors := OrderedCollection new.
 self allChildrenDepthFirstDo: [ :element | (element isKindOf: BrEditor) ifTrue: [ editors add: element ] ].
 origin := editors indexOf: anchor key.
 origin = 0 ifTrue: [ ^ self ].
 destination := editors indexOf: (self replyEditorNearest: event position among: editors).
 previous := self userData at: #replySelectedEditors ifAbsent: [ #() ].
 (destination = origin and: [ previous isEmpty ]) ifTrue: [ ^ self ].
 index := self replyTextIndexAt: event position in: (editors at: destination).
 index ifNil: [ ^ self ].
 first := origin min: destination. last := origin max: destination.
 from := destination < origin ifTrue: [ index ] ifFalse: [ anchor value ].
 to := destination < origin ifTrue: [ anchor value ] ifFalse: [ index ].
 selected := editors copyFrom: first to: last.
 previous do: [ :element | (selected includes: element) ifFalse: [ element editor deselectAll ] ].
 first to: last do: [ :position | | model left right |
  model := (editors at: position) editor.
  left := position = first ifTrue: [ from ] ifFalse: [ 0 ].
  right := position = last ifTrue: [ to ] ifFalse: [ model text size ].
  left = right
   ifTrue: [ model deselectAll ]
   ifFalse: [ model selecter overwrite; from: (left min: right) to: (left max: right); withoutCursorUpdate; select ] ].
 self userData at: #replySelectedEditors put: selected.
 event consumed: true'.
cls compile: 'replyEditorNearest: point among: editors
 | nearest smallestDistance |
 editors do: [ :element | | bounds dx dy distance |
  bounds := element localBoundsToGlobal: (BlBounds origin: 0 @ 0 extent: element extent).
  dx := ((bounds left - point x) max: (point x - bounds right)) max: 0.
  dy := ((bounds top - point y) max: (point y - bounds bottom)) max: 0.
  distance := dx squared + dy squared.
  distance = 0 ifTrue: [ ^ element ].
  (smallestDistance isNil or: [ distance < smallestDistance ]) ifTrue: [
   nearest := element. smallestDistance := distance ] ].
 ^ nearest'.
cls compile: 'replyTextIndexAt: point in: element
 | local |
 local := element globalPointToLocal: point.
 local y < 0 ifTrue: [ ^ 0 ].
 local y >= element height ifTrue: [ ^ element editor text size ].
 ^ element editor navigator
  findTextIndexAtScreenPosition: (((local x max: 0) min: (element width - 1 max: 0)) @ local y)
  ifAbsent: [ nil ]'.
cls compile: 'copyReplySelection
 | editors parts |
 editors := self userData at: #replySelectedEditors ifAbsent: [ ^ false ].
 parts := (editors collect: [ :element | element editor selectedText asString ]) reject: #isEmpty.
 parts ifEmpty: [ ^ false ].
 GtClipboard clipboardText: (String lf join: parts).
 ^ true'.
cls compile: 'isBoundary: lines at: index
 | line fence |
 line := (lines at: index) trimBoth.
 line ifEmpty: [ ^ true ].
 fence := String new: 3 withAll: (Character value: 96).
 ^ (line beginsWith: fence) or: [
  (#(''# '' ''## '' ''### '' ''#### '' ''##### '' ''###### '') anySatisfy: [ :prefix | line beginsWith: prefix ])
   or: [ (line beginsWith: ''>'') or: [ (self listPrefix: line) notNil or: [
   index < lines size and: [ self isTableSeparator: (lines at: index + 1) ] ] ] ] ]'.
cls compile: 'isTableSeparator: line
 | cells |
 cells := LMChatStyle tableCells: line.
 ^ cells notEmpty and: [ cells allSatisfy: [ :cell |
  | value |
  value := cell copyWithout: $:.
  value size >= 3 and: [ value allSatisfy: [ :char | char = $- ] ] ] ]'.
cls compile: 'listPrefix: line
 | value dot |
 value := line trimBoth.
 ((value beginsWith: ''- '') or: [ value beginsWith: ''* '' ]) ifTrue: [ ^ ''•'' ].
 dot := value indexOf: $..
 (dot > 1 and: [ dot < value size and: [ (value at: dot + 1) = Character space and: [
  (value first: dot - 1) allSatisfy: #isDigit ] ] ]) ifTrue: [ ^ value first: dot ].
 ^ nil'.
cls compile: 'parseBlocks: markdown
 | lines result index line fence content language level prefix parts header rows |
 lines := markdown lines asArray.
 result := OrderedCollection new. index := 1.
 fence := String new: 3 withAll: (Character value: 96).
 [ index <= lines size ] whileTrue: [
  line := (lines at: index) trimBoth.
  line isEmpty
   ifTrue: [ index := index + 1 ]
   ifFalse: [
    (line beginsWith: fence)
     ifTrue: [
      language := (line allButFirst: 3) trimBoth.
      parts := OrderedCollection new. index := index + 1.
      [ index <= lines size and: [ ((lines at: index) trimBoth beginsWith: fence) not ] ]
       whileTrue: [ parts add: (lines at: index). index := index + 1 ].
      index <= lines size ifTrue: [ index := index + 1 ].
      content := String streamContents: [ :out | parts doWithIndex: [ :part :n | n > 1 ifTrue: [ out cr ]. out nextPutAll: part ] ].
      result add: { #code. language. content } ]
     ifFalse: [
      level := 0.
      [ level < line size and: [ level < 6 and: [ (line at: level + 1) = $# ] ] ] whileTrue: [ level := level + 1 ].
      (level > 0 and: [ level < line size and: [ (line at: level + 1) = Character space ] ])
       ifTrue: [ result add: { #heading. level. (line allButFirst: level + 1) }. index := index + 1 ]
       ifFalse: [
        (index < lines size and: [ (line includes: $|) and: [ self isTableSeparator: (lines at: index + 1) ] ])
         ifTrue: [
          header := LMChatStyle tableCells: line. rows := OrderedCollection new. index := index + 2.
          [ index <= lines size and: [ (lines at: index) includes: $| ] ] whileTrue: [
           rows add: (LMChatStyle tableCells: (lines at: index)). index := index + 1 ].
          result add: { #table. header. rows asArray } ]
         ifFalse: [
          (line beginsWith: ''>'')
           ifTrue: [
            parts := OrderedCollection new.
            [ index <= lines size and: [ (lines at: index) trimBoth beginsWith: ''>'' ] ] whileTrue: [
             parts add: (((lines at: index) trimBoth allButFirst) trimBoth). index := index + 1 ].
            result add: { #quote. (String streamContents: [ :out | parts doWithIndex: [ :part :n | n > 1 ifTrue: [ out cr ]. out nextPutAll: part ] ]) } ]
           ifFalse: [
            prefix := self listPrefix: line.
            prefix notNil
             ifTrue: [
              content := prefix = ''•'' ifTrue: [ line allButFirst: 2 ] ifFalse: [ (line allButFirst: prefix size) trimLeft ].
              result add: { #list. prefix. content }. index := index + 1 ]
             ifFalse: [
              (line = ''---'' or: [ line = ''***'' ])
               ifTrue: [ result add: { #rule. '''' }. index := index + 1 ]
               ifFalse: [
                parts := OrderedCollection with: line. index := index + 1.
                [ index <= lines size and: [ (self isBoundary: lines at: index) not ] ] whileTrue: [
                 parts add: (lines at: index) trimBoth. index := index + 1 ].
                content := String streamContents: [ :out | parts doWithIndex: [ :part :n | n > 1 ifTrue: [ out space ]. out nextPutAll: part ] ].
                result add: { #paragraph. content } ] ] ] ] ] ] ] ].
 ^ result asArray'.
cls compile: 'source ^ source ifNil: [ '''' ]'.
cls compile: 'text: markdown
 | next common |
 source = markdown ifTrue: [ ^ self ].
 self clearReplySelection.
 source := markdown.
 next := self parseBlocks: markdown.
 common := specs size min: next size.
 1 to: common do: [ :index |
  (specs at: index) = (next at: index) ifFalse: [
   | view old |
   old := views at: index.
   view := self blockView: (next at: index).
   self replaceChild: old with: view.
   views at: index put: view ] ].
 [ views size > next size ] whileTrue: [ views removeLast removeFromParent ].
 views size + 1 to: next size do: [ :index | | view |
  view := self blockView: (next at: index). views add: view. self addChild: view ].
 specs := next.
 ^ self'.
cls := (BrVerticalPane << #LMConversationMessageView slots: #(#controller #descriptor #body #bodyHolder #stateLabel #actions #rawShown #userMetadataLabel #voiceButton #voiceDuration #voiceStatus); package: 'Loom-Interface') install.
(cls includesSelector: #thumbnailFor:) ifTrue: [ cls removeSelector: #thumbnailFor: ].
cls compile: 'build
 | bubble content role |
 role := descriptor at: ''role''.
 role = ''user'' ifTrue: [
  content := BrVerticalPane new hMatchParent; vFitContent; alignTopRight; yourself.
  bubble := BrVerticalPane new hExact: 200; vFitContent;
  padding: (BlInsets top: 9 right: 13 bottom: 9 left: 13);
   background: (Color gray: 0.965);
   border: (BlBorder paint: (Color gray: 0.9) width: 1);
   geometry: (BlRoundedRectangleGeometry cornerRadius: 8); yourself.
  (descriptor includesKey: ''audio'') ifTrue: [ self addRecordingPlayerTo: bubble ].
  body := LMChatStyle readOnly: (descriptor at: ''text'') trimBoth size: 14.
  bubble addChild: body.
  content addChild: bubble.
  self addAttachmentsTo: content.
  self addChild: content.
  userMetadataLabel := (LMChatStyle label: '''' size: 12) hMatchParent; alignCenterRight; yourself.
  self addChild: userMetadataLabel.
  ^ self ].
 stateLabel := (LMChatStyle label: '''' size: 12) hMatchParent; vExact: 19; yourself.
 self addChild: stateLabel.
 bodyHolder := BrVerticalPane new hMatchParent; vFitContent; yourself.
 body := self replyBody.
 bodyHolder addChild: body. self addChild: bodyHolder.
 actions := self replyActions.
 self addChild: actions'.
cls compile: 'addAttachmentsTo: content
 (descriptor at: ''attachments'' ifAbsent: [ #() ]) do: [ :attachment |
  | name file card icon caption available |
  name := attachment at: ''name''.
  file := LoomConversation fileForAttachment: attachment.
  available := file exists.
  icon := LMChatStyle attachmentIconForImage: (attachment at: ''image'' ifAbsent: [
   LMConversationStore isImageExtension: name asFileReference extension ]) size: 18.
  icon margin: (BlInsets right: 8).
  caption := BrVerticalPane new hMatchParent; vFitContent; alignTopLeft; yourself.
  card := BrButton new id: #loomAttachmentCard; aptitude: BrGlamorousButtonLayoutAptitude new;
   label: name; beFocusable; alignCenterLeft;
   padding: (BlInsets left: 12 right: 12);
   margin: (BlInsets top: 4);
   action: [ self openAttachment: file ]; enabled: available; yourself.
  card addAptitude: (LMChatStyle attachmentSurfaceAptitude
   hovered: [ :style | style background: (Color gray: 0.93) ];
   focused: [ :style | style border: (BlBorder paint: (Color gray: 0.55) width: 1) ]).
  card addAptitude: (BrGlamorousWithExplicitTooltipAptitude new content: [ self attachmentTooltipFor: name ]).
  card addChildren: { icon. caption }.
  card userData at: #preferredWidth put: ((LMChatStyle measureLabel: name size: 13) ceiling + 52 max: 112).
  self sizeAttachmentCard: card within: 380.
  content addChild: card ]'.
cls compile: 'sizeAttachmentCard: card within: limit
 | data width caption lines |
 data := card userData.
 width := ((limit min: 380) min: (data at: #preferredWidth ifAbsent: [ ^ self ])) floor.
 (data at: #width ifAbsent: [ nil ]) = width ifTrue: [ ^ self ].
 data at: #width put: width.
 caption := card children second.
 caption removeChildren.
 lines := self attachmentNameLines: card label asString at: width - 52.
 lines do: [ :line | caption addChild: (LMChatStyle label: line size: 13) ].
 card states isDisabled ifTrue: [ caption addChild: (LMChatStyle label: ''附件找不到'' size: 12) ].
 card hExact: width; vExact: 18 + (caption children size * 20)'.
cls compile: 'attachmentNameLines: name at: width
 | first rest low high middle |
 first := LMChatStyle ellipsize: name at: width size: 13.
 first = name ifTrue: [ ^ { name } ].
 first := first allButLast.
 rest := name allButFirst: first size.
 (LMChatStyle measureLabel: rest size: 13) <= width ifTrue: [ ^ { first. rest } ].
 low := 0. high := rest size.
 [ low < high ] whileTrue: [
  middle := (low + high + 1) // 2.
  (LMChatStyle measureLabel: ''…'', (rest last: middle) size: 13) <= width
   ifTrue: [ low := middle ] ifFalse: [ high := middle - 1 ] ].
 ^ { first. ''…'', (rest last: low) }'.
cls compile: 'attachmentTooltipFor: name
 | pane remaining line |
 pane := BrVerticalPane new hFitContent; vFitContent; yourself.
 remaining := name.
 [ remaining notEmpty ] whileTrue: [
  line := LMChatStyle ellipsize: remaining at: 320 size: 12.
  line = remaining ifFalse: [ line := line allButLast ].
  pane addChild: (LMChatStyle label: line size: 12).
  remaining := remaining allButFirst: line size ].
 ^ pane'.
cls compile: 'openAttachment: file
 file exists
  ifTrue: [ WebBrowser openOn: file fullName ]
  ifFalse: [ controller ifNotNil: [ controller voiceNotice: ''附件找不到'' ] ]'.
cls compile: 'addRecordingPlayerTo: bubble
 voiceButton := LMChatStyle replyAction: #voiceMessagePlay icon: ''play'' action: [
  controller ifNotNil: [ controller toggleRecordingPlayback: ((descriptor at: ''audio'') at: ''id'') ] ].
 voiceButton hFitContent; vExact: 26;
  layout: (BlLinearLayout horizontal
   verticalAlignment: BlElementAlignment vertical center; cellSpacing: 3; yourself);
  padding: (BlInsets left: 6 right: 7);
  background: Color white;
  border: (BlBorder paint: (Color gray: 0.89) width: 1);
  geometry: (BlRoundedRectangleGeometry cornerRadius: 6).
 voiceDuration := LMChatStyle label: '''' size: 12.
 voiceDuration aptitude foreground: (Color gray: 0.36).
 voiceButton addChild: voiceDuration.
 voiceStatus := (LMChatStyle label: '''' size: 12) id: #voiceMessageStatus; hMatchParent; yourself.
 voiceStatus aptitude foreground: (Color gray: 0.42).
 bubble padding: (BlInsets top: 7 right: 11 bottom: 7 left: 11).
 bubble layout cellSpacing: 3.
 bubble addChildren: { voiceButton. voiceStatus }'.
cls compile: 'renderRecording: audio
 | duration seconds caption playing icon |
 duration := (audio at: ''duration'') rounded.
 seconds := duration \\ 60.
 voiceDuration text: (duration // 60) asString, '':'',
  (seconds < 10 ifTrue: [ ''0'' ] ifFalse: [ '''' ]), seconds asString.
 caption := audio at: ''status''.
 voiceStatus text: caption;
  visibility: (caption isEmpty ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]).
 body visibility: ((descriptor at: ''text'') trimBoth isEmpty ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]).
 voiceButton enabled: (audio at: ''playable'').
 playing := audio at: ''playing''.
 (voiceButton userData at: #playing ifAbsent: [ nil ]) = playing ifFalse: [
  icon := LMIcons iconNamed: (playing ifTrue: [ ''square'' ] ifFalse: [ ''play'' ]).
  voiceButton replaceChild: voiceButton children first with: icon.
  voiceButton label: (playing ifTrue: [ ''停止播放'' ] ifFalse: [ ''播放原音'' ]).
  voiceButton userData at: #playing put: playing ]'.
cls compile: 'controller: aController controller := aController'.
cls compile: 'copyReplyWith: button
 GtClipboard clipboardText: (descriptor at: ''text'').
 self flashCopyFeedbackOn: button'.
cls compile: 'flashCopyFeedbackOn: button
 | timer original check |
 timer := button userData at: #copyFeedback ifAbsent: [ nil ].
 timer ifNotNil: [ ^ timer startOrRestart ].
 original := button children first.
 check := LMIcons iconNamed: ''check''.
 check constraintsDo: [ :c | c frame horizontal alignCenter. c frame vertical alignCenter ].
 button replaceChild: original with: check.
 timer := BlDelayedTaskAction new delay: 1400 milliSeconds;
  action: [
   button replaceChild: check with: original.
   button userData removeKey: #copyFeedback ifAbsent: [ ] ]; yourself.
 button userData at: #copyFeedback put: timer.
 button enqueueTask: timer'.
cls compile: 'descriptor: value
 | rebuild role caption text attachmentOnly |
 rebuild := descriptor isNil or: [
  (descriptor at: ''id'') ~= (value at: ''id'') or: [
   (descriptor at: ''role'') ~= (value at: ''role'') or: [
    (descriptor includesKey: ''audio'') ~= (value includesKey: ''audio'') or: [
     (descriptor at: ''attachments'' ifAbsent: [ #() ]) ~= (value at: ''attachments'' ifAbsent: [ #() ]) ] ] ] ].
 role := value at: ''role''.
 (role = ''user'' and: [ userMetadataLabel isNil ]) ifTrue: [ rebuild := true ].
 rebuild ifTrue: [ rawShown := controller ifNil: [ false ] ifNotNil: [ controller messageSourceFor: (value at: ''id'') ]. self removeChildren. descriptor := value. self build ].
 descriptor := value.
 role = ''user''
  ifTrue: [
   text := (value at: ''text'') trimBoth.
   body text: (LMChatStyle formattedText: text size: 14).
   attachmentOnly := text isEmpty and: [ (value includesKey: ''audio'') not
    and: [ (value at: ''attachments'' ifAbsent: [ #() ]) notEmpty ] ].
   body parent visibility: (attachmentOnly ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]).
   value at: ''audio'' ifPresent: [ :audio | self renderRecording: audio ].
   caption := self userMetadata.
   userMetadataLabel text: caption;
    visibility: (caption isEmpty ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]) ]
  ifFalse: [
   rawShown
    ifTrue: [ body text: (LMChatStyle formattedText: (value at: ''text'') size: 13) ]
    ifFalse: [ body text: (value at: ''text'') ].
   actions visibility: ((value at: ''pending'' ifAbsent: [ false ]) ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]).
   caption := (value at: ''pending'' ifAbsent: [ false ])
    ifTrue: [ (value at: ''text'') ifEmpty: [ ''正在处理…'' ] ifNotEmpty: [ ''正在回复…'' ] ]
    ifFalse: [ (value at: ''ok'' ifAbsent: [ true ]) ifTrue: [ '''' ] ifFalse: [ ''未完成'' ] ].
   stateLabel text: caption;
    visibility: (caption isEmpty ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]) ].
 self updateGeometry'.
cls compile: 'initialize
 super initialize.
 self hMatchParent; vFitContent; padding: (BlInsets top: 8 right: 25 bottom: 9 left: 25).
 self layout cellSpacing: 3.
 self addEventHandlerOn: BlElementExtentChangedEvent do: [ :event | self updateGeometry ].
 rawShown := false'.
cls compile: 'replyActions
 | copy source |
 copy := LMChatStyle replyAction: #copyReply icon: ''copy''
  action: [ :button | self copyReplyWith: button ].
 source := LMChatStyle replyAction: #viewMarkdownSource icon: ''code-xml'' action: [ self toggleSource ].
 ^ BrHorizontalPane new hMatchParent; vExact: 24;
  transformDo: [ :transform | transform translateBy: -5 @ 0 ];
  visibility: ((descriptor at: ''pending'' ifAbsent: [ false ]) ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ]);
  addChildren: { copy. source }; yourself'.
cls compile: 'replyBody
 | text |
 text := descriptor at: ''text''.
 rawShown ifTrue: [ ^ LMChatStyle readOnly: text size: 13 ].
 ^ LMMarkdownView new text: text; yourself'.
cls compile: 'showRenderingError: error descriptor: value
 descriptor := nil. self removeChildren.
 self addChild: (LMChatStyle label: ''这条消息暂时无法排版'' size: 13).
 self addChild: (LMChatStyle flatButton: ''复制原文'' action: [ GtClipboard clipboardText: (value at: ''text'' ifAbsent: [ '''' ]) ]).
 ^ self'.
cls compile: 'toggleSource
 rawShown := rawShown not.
 controller ifNotNil: [ controller messageSource: rawShown for: (descriptor at: ''id'') ].
 bodyHolder removeChildren.
 body := self replyBody.
 bodyHolder addChild: body'.
cls compile: 'updateGeometry
 | inset padding ideal limit target bubble viewport |
 (descriptor isNil or: [ self width <= 100 ]) ifTrue: [ ^ self ].
 viewport := controller ifNil: [ self width ] ifNotNil: [ controller viewportWidth ifNil: [ self width ] ].
 inset := LMChatStyle readingInsetFor: self width viewport: viewport padding: 18 medium: 16 narrow: 12.
 padding := BlInsets top: ((descriptor at: ''role'') = ''user'' ifTrue: [ 13 ] ifFalse: [ 8 ]) right: inset bottom: 9 left: inset.
 self padding = padding ifFalse: [ self padding: padding ].
 (descriptor at: ''role'') = ''user'' ifTrue: [
  (body isNil or: [ body parent isNil ]) ifTrue: [ ^ self ].
  ideal := (descriptor at: ''text'') trimBoth lines inject: 0 into: [ :largest :line |
   largest max: (LMChatStyle measureLabel: line size: 14) ].
  descriptor at: ''audio'' ifPresent: [ :audio |
   ideal := ideal max: (LMChatStyle measureLabel: voiceDuration text asString size: 12) + 38.
   ideal := ideal max: (LMChatStyle measureLabel: (audio at: ''status'') size: 12) ].
  limit := (self width - (inset * 2)) * (viewport <= 800 ifTrue: [ 0.94 ] ifFalse: [ 0.88 ]).
  target := ((ideal ceiling + 37) min: limit) max: 54.
  bubble := body parent.
  (bubble width - target) abs > 0.5 ifTrue: [ bubble hExact: target ].
  bubble parent children do: [ :child |
   child == bubble ifFalse: [ self sizeAttachmentCard: child within: limit ] ] ]'.
cls compile: 'userMetadata
 | stamp date hour minute |
 stamp := descriptor at: ''createdAt'' ifAbsent: [ '''' ].
 (stamp isNil or: [ stamp isEmpty ]) ifTrue: [ ^ '''' ].
 [ date := (DateAndTime fromString: stamp) asLocal.
   hour := date hour. minute := date minute.
   ^ (hour < 10 ifTrue: [ ''0'' ] ifFalse: [ '''' ]), hour asString, '':'',
    (minute < 10 ifTrue: [ ''0'' ] ifFalse: [ '''' ]), minute asString
 ] on: Error do: [ :error | ^ '''' ]'.
cls := (BrVerticalPane << #LMConversationActivityView slots: #(#controller #descriptor #expanded #mode #summary #mark #title #tool #duration #chevron #details #detailCache #preview); package: 'Loom-Interface') install.
(cls includesSelector: #detailValue) ifTrue: [ cls removeSelector: #detailValue ].
cls compile: 'actionTitle
 | type code toolName |
 (descriptor at: ''title'' ifAbsent: [ nil ]) ifNotNil: [ :caption | ^ caption ].
 type := descriptor at: ''type''.
 type = ''agentMessage'' ifTrue: [ ^ self shorten: (descriptor at: ''text'') limit: 44 ].
 type = ''reasoning'' ifTrue: [ ^ ''思考摘要'' ].
 type = ''plan'' ifTrue: [ ^ ''计划'' ].
 type = ''commandExecution'' ifTrue: [ ^ ''执行命令'' ].
 type = ''fileChange'' ifTrue: [ ^ ''修改文件'' ].
 type = ''webSearch'' ifTrue: [ ^ ''搜索资料'' ].
 toolName := descriptor at: ''tool'' ifAbsent: [ ''工具调用'' ].
 (#(''pharo_eval'' ''runtime_eval'') includes: toolName) ifTrue: [
  code := descriptor at: ''codePreview'' ifAbsent: [ descriptor at: ''arguments'' ifAbsent: [ Dictionary new ] ].
  code isDictionary ifTrue: [ code := code at: ''code'' ifAbsent: [ '''' ] ].
  code isString ifFalse: [ code := '''' ].
  (code includesSubstring: ''compile:'') ifTrue: [ ^ ''编译运行方法'' ].
  (code includesSubstring: ''writeStream'') ifTrue: [ ^ ''写入文件'' ].
  (code includesSubstring: ''sourceCode'') ifTrue: [ ^ ''读取代码实现'' ].
  (code includesSubstring: ''checkpoint'') ifTrue: [ ^ ''保存检查点'' ].
  ^ ''执行 Smalltalk'' ].
 ^ toolName'.
cls compile: 'build
 summary := BrButton new aptitude: BrGlamorousButtonLayoutAptitude new; action: [ self toggle ]; yourself.
 summary addAptitude: (BrStyleCommonAptitude new
  default: [ :style | style background: Color transparent ];
  hovered: [ :style | style background: (Color gray: 0.95) ]).
 summary hMatchParent; vExact: 32; alignCenterLeft; padding: (BlInsets left: 6 right: 7).
 summary layout cellSpacing: 6.
 mark := BrHorizontalPane new hExact: 16; vExact: 16; alignCenter; yourself.
 title := (LMChatStyle label: '''' size: 13) hMatchParent; yourself.
 tool := LMChatStyle label: '''' size: 12.
 tool aptitude fontName: ''Consolas''; foreground: (Color gray: 0.58).
 duration := LMChatStyle label: '''' size: 12.
 duration aptitude foreground: (Color gray: 0.55).
 chevron := BrHorizontalPane new hExact: 14; vExact: 14; alignCenter; yourself.
 summary addChildren: { mark. title. tool. duration. chevron }.
 self addChild: summary.
 preview := (LMChatStyle readOnly: '''' size: 13) vExact: 22; margin: (BlInsets left: 28); yourself.
 self addChild: preview'.
cls compile: 'controller: aController controller := aController'.
cls compile: 'descriptor: value
 | changedId wasFailed |
 changedId := preview isNil or: [ descriptor isNil or: [ (descriptor at: ''id'') ~= (value at: ''id'') ] ].
 wasFailed := descriptor notNil and: [ self isFailed ].
 descriptor := value.
 changedId ifTrue: [
  expanded := controller ifNil: [ false ] ifNotNil: [ controller activityExpandedFor: (value at: ''id'') ].
  mode := controller ifNil: [ #arguments ] ifNotNil: [ controller activityDetailModeFor: (value at: ''id'') ].
  self userData removeKey: #detailRequest ifAbsent: [ ].
  self userData removeKey: #detailText ifAbsent: [ ].
  detailCache := nil. self removeChildren. self build ].
 (self isFailed and: [ wasFailed not and: [ changedId not ] ]) ifTrue: [
  expanded := true. mode := #result.
  controller ifNotNil: [ controller activityExpanded: true for: (value at: ''id'');
   activityDetailMode: #result for: (value at: ''id'') ] ].
 self updateSummary.
 expanded ifTrue: [ self updateDetails ] ifFalse: [
  details ifNotNil: [ details removeFromParent. details := nil ] ]'.
cls compile: 'detailTextFrom: row mode: tab
 | value |
 value := tab = #text ifTrue: [ row at: ''text'' ifAbsent: [ '''' ] ] ifFalse: [
  tab = #arguments
   ifTrue: [ row at: ''arguments'' ifAbsent: [ row at: ''command'' ifAbsent: [ '''' ] ] ]
   ifFalse: [ row at: ''contentItems'' ifAbsent: [ row at: ''result'' ifAbsent: [
    row at: ''aggregatedOutput'' ifAbsent: [ row at: ''error'' ifAbsent: [ row at: ''changes'' ifAbsent: [ '''' ] ] ] ] ] ] ].
 ^ value ifNil: [ '''' ] ifNotNil: [ LMConversationStream new displayValue: value ]'.
cls compile: 'activityDetailText
 | seq tab version cached token |
 tab := self isTool ifTrue: [ mode ] ifFalse: [ #text ].
 controller ifNil: [ ^ self detailTextFrom: descriptor mode: tab ].
 seq := descriptor at: ''seq'' ifAbsent: [ ^ self detailTextFrom: descriptor mode: tab ].
 version := descriptor at: ''revision''.
 cached := self userData at: #detailText ifAbsent: [ nil ].
 (cached notNil and: [ cached first = tab and: [ cached second >= version ] ]) ifTrue: [ ^ cached third ].
 (self userData includesKey: #detailRequest) ifFalse: [
  token := Object new.
  self userData at: #detailRequest put: token.
  [ | result |
   result := [
    (LoomNativeCodexHost registry activityDetailAt: seq) ifNil: [
     { tab. version. ''这条活动已不可用'' } ] ifNotNil: [ :entry |
     { tab. entry at: ''revision''. self detailTextFrom: (entry at: ''data'') mode: tab } ]
   ] on: Error do: [ :error | { tab. version. ''读取详情失败：'', error messageText } ].
   controller defer: [
    (self userData at: #detailRequest ifAbsent: [ nil ]) == token ifTrue: [
     self userData removeKey: #detailRequest.
     self userData at: #detailText put: result.
     expanded ifTrue: [ self updateDetails ] ] ]
  ] fork ].
 ^ cached ifNotNil: [ cached first = tab ifTrue: [ cached third ] ifFalse: [ nil ] ]'.
cls compile: 'initialize
 super initialize.
 self hMatchParent; vFitContent; padding: (BlInsets top: 0 right: 12 bottom: 4 left: 12).
 self addEventHandlerOn: BlElementExtentChangedEvent do: [ :event | self fitSummary ].
 expanded := false. mode := #arguments'.
cls compile: 'isFailed
 ^ (descriptor at: ''success'' ifAbsent: [ nil ]) = false
  or: [ #(''failed'' ''declined'' ''已中断或失败'') includes: (descriptor at: ''status'' ifAbsent: [ '''' ]) ]'.
cls compile: 'isInterrupted
 ^ (descriptor at: ''status'' ifAbsent: [ '''' ]) = ''interrupted'''.
cls compile: 'isRunning
 ^ #(''inProgress'' ''pending'' ''进行中'') includes: (descriptor at: ''status'' ifAbsent: [ '''' ])'.
cls compile: 'isTool
 ^ #(''dynamicToolCall'' ''mcpToolCall'' ''commandExecution'' ''webSearch'' ''fileChange'') includes: (descriptor at: ''type'')'.
cls compile: 'progressParts
 | value cut head rest |
 value := (descriptor at: ''text'' ifAbsent: [ '''' ]) trimBoth.
 value ifEmpty: [ ^ { ''''. '''' } ].
 (descriptor at: ''title'' ifAbsent: [ nil ]) ifNotNil: [ :caption |
  ^ { caption. ((value beginsWith: (caption, ''。''))
   ifTrue: [ value allButFirst: caption size + 1 ] ifFalse: [ value ]) } ].
 cut := value indexOf: (Character value: 12290).
 (cut > 0 and: [ cut <= 28 ])
  ifTrue: [ head := value first: cut - 1. rest := (value allButFirst: cut) trimBoth ]
  ifFalse: [
   value size > 24
    ifTrue: [ head := value first: 24. rest := (value allButFirst: 24) trimBoth ]
    ifFalse: [ head := value. rest := '''' ] ].
 ^ { head. rest }'.
cls compile: 'shorten: value limit: limit
 | line |
 line := value lines ifEmpty: [ '''' ] ifNotEmpty: [ :lines | lines first ].
 ^ line size > limit ifTrue: [ (line first: limit), ''…'' ] ifFalse: [ line ]'.
cls compile: 'showDetailMode: aSymbol
 mode := aSymbol.
 controller ifNotNil: [ controller activityDetailMode: aSymbol for: (descriptor at: ''id'') ].
 self updateDetails'.
cls compile: 'showRenderingError: error descriptor: value
 descriptor := value. preview := nil. details := nil.
 self removeChildren.
 self addChild: (LMChatStyle label: ''活动暂时无法排版，原始事件仍已保留'' size: 13).
 self addChild: (LMChatStyle label: (error messageText first: (error messageText size min: 90)) size: 12).
 ^ self'.
cls compile: 'activityIconName
 self isInterrupted ifTrue: [ ^ ''circle-minus'' ].
 self isFailed ifTrue: [ ^ ''circle-alert'' ].
 self isRunning ifTrue: [ ^ ''loader-circle'' ].
 ^ (descriptor at: ''type'') caseOf: {
  [ ''commandExecution'' ] -> [ ''terminal'' ].
  [ ''fileChange'' ] -> [ ''file-pen-line'' ].
  [ ''webSearch'' ] -> [ ''search'' ].
  [ ''agentMessage'' ] -> [ ''message-square'' ].
  [ ''reasoning'' ] -> [ ''brain'' ].
  [ ''plan'' ] -> [ ''list-checks'' ].
  [ ''loomActivity'' ] -> [ ''activity'' ] } otherwise: [ ''wrench'' ]'.
cls compile: 'toggle
 self hasDetails ifFalse: [ ^ self ].
 expanded := expanded not.
 controller ifNotNil: [ controller activityExpanded: expanded for: (descriptor at: ''id'') ]. self updateSummary.
 expanded ifTrue: [ self updateDetails ] ifFalse: [ details ifNotNil: [ details removeFromParent. details := nil ] ]'.
cls compile: 'hasDetails
 ^ (descriptor at: ''type'') ~= ''loomActivity'' or: [ (descriptor at: ''text'' ifAbsent: [ '''' ]) notEmpty ]'.
cls compile: 'updateDetails
 | value text pane tabs editor height copy |
 value := self activityDetailText.
 text := value ifNil: [ ''正在读取详情…'' ].
 (details notNil and: [ detailCache = { mode. text } ]) ifTrue: [ ^ self ].
 detailCache := { mode. text }.
 details ifNotNil: [ details removeFromParent ].
 pane := BrVerticalPane new hMatchParent; vFitContent;
  margin: (BlInsets top: 4 bottom: 4);
  padding: (BlInsets top: 7 right: 9 bottom: 8 left: 9); background: Color white;
  geometry: (BlRoundedRectangleGeometry cornerRadius: 6);
  border: (BlBorder paint: (Color gray: 0.89) width: 1); yourself.
 self isTool ifTrue: [
  tabs := BrHorizontalPane new hMatchParent; vExact: 28; yourself.
  tabs layout cellSpacing: 4.
  tabs addChild: (self detailTab: ''参数'' mode: #arguments).
  tabs addChild: (self detailTab: ''结果'' mode: #result).
  tabs addChild: (BrHorizontalPane new hMatchParent; vExact: 1; yourself).
  copy := LMChatStyle replyAction: #copyActivityDetail icon: ''copy''
   action: [ GtClipboard clipboardText: value ].
  copy enabled: value notNil.
  tabs addChild: copy.
  pane addChild: tabs ].
 text ifEmpty: [ text := self isInterrupted ifTrue: [ ''本轮已中断，执行结果未确认。'' ] ifFalse: [
 self isRunning ifTrue: [ ''等待执行结果…'' ] ifFalse: [ ''无附加内容'' ] ] ].
 text size > 16000 ifTrue: [ text := (text first: 16000), String cr, ''…（可复制完整内容）'' ].
 height := (((text lines size + (text size // 55)) * 18 + 18) min: 240) max: 55.
 editor := (LMChatStyle readOnly: text size: 13) vExact: height; yourself.
 pane addChild: editor.
 details := pane. self addChild: details'.
cls compile: 'detailTab: caption mode: tabMode
 ^ (LMChatStyle button: caption action: [ self showDetailMode: tabMode ]
  foreground: (Color gray: 0.24) background: (mode = tabMode ifTrue: [ Color gray: 0.93 ] ifFalse: [ Color white ]))
  geometry: (BlRoundedRectangleGeometry cornerRadius: 4); yourself'.
cls compile: 'updateSummary
 | label icon |
 summary enabled: self hasDetails.
 self hasDetails ifFalse: [ expanded := false ].
 chevron visibility: (self hasDetails ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ]).
 icon := self activityIconName.
 (mark userData at: #iconName ifAbsent: [ nil ]) = icon ifFalse: [
  mark userData at: #iconName put: icon.
  mark removeChildren; addChild: (LMIcons iconNamed: icon size: 15 color: (Color gray: 0.45)) ].
 tool visibility: (self isTool ifTrue: [ BlVisibility visible ] ifFalse: [ BlVisibility gone ]).
 tool text: ((descriptor at: ''tool'' ifAbsent: [ '''' ]) asRopedText fontName: ''Consolas''; fontSize: 12; foreground: (Color gray: 0.58); yourself).
 label := self isInterrupted ifTrue: [ ''中断'' ] ifFalse: [ self isFailed ifTrue: [ ''失败'' ] ifFalse: [
  self isRunning ifTrue: [ ''执行中'' ] ifFalse: [
   (descriptor at: ''durationMs'' ifAbsent: [ nil ]) ifNil: [ '''' ] ifNotNil: [ :ms | ms asString, '' ms'' ] ] ] ].
 duration text: (label asRopedText foreground: (Color gray: 0.55); yourself).
 (chevron userData at: #expanded ifAbsent: [ nil ]) = expanded ifFalse: [
  chevron userData at: #expanded put: expanded.
  chevron removeChildren; addChild: (LMChatStyle chevron: expanded) ].
 summary geometry: (BlRoundedRectangleGeometry cornerRadius: 5).
 summary background: ((expanded or: [ self isRunning ]) ifTrue: [ Color gray: 0.94 ] ifFalse: [ Color transparent ]).
 self fitSummary'.
cls compile: 'fitSummary
 | width parts name subtitle toolWidth durationWidth display |
 (descriptor isNil or: [ summary isNil or: [ summary parent isNil ] ]) ifTrue: [ ^ self ].
 width := self width - self padding left - self padding right.
 parts := self isTool ifTrue: [ { self actionTitle. '''' } ] ifFalse: [
  (descriptor at: ''type'') = ''agentMessage''
   ifTrue: [ self progressParts ] ifFalse: [ { self actionTitle. descriptor at: ''text'' } ] ].
 name := parts first. subtitle := parts second.
 toolWidth := 0. durationWidth := 0.
 self isTool ifTrue: [
  toolWidth := LMChatStyle measureLabel: tool text asString size: 12.
  durationWidth := LMChatStyle measureLabel: duration text asString size: 12.
  (width > 0 and: [ width - durationWidth - toolWidth < 125 ])
   ifTrue: [ tool visibility: BlVisibility gone. toolWidth := 0 ]
   ifFalse: [ tool visibility: BlVisibility visible ] ].
 display := LMChatStyle ellipsize: (self shorten: name limit: 100)
  at: width - toolWidth - durationWidth - 62 size: 13.
 title text asString = display ifFalse: [ title text: display ].
 display := LMChatStyle ellipsize: (self shorten: subtitle limit: 160) at: width - 35 size: 13.
 preview text asString = display ifFalse: [
  preview text: ((LMChatStyle formattedText: display size: 13) foreground: (Color gray: 0.48); yourself) ].
 preview visibility: ((subtitle isEmpty or: [ expanded ]) ifTrue: [ BlVisibility gone ] ifFalse: [ BlVisibility visible ])'.
'native conversation components installed'
