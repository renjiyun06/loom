"Loom's offline Lucide registry. SVG elements become native Bloc graphics."
| icons |
icons := (Object << #LMIcons slots: #(); package: 'Loom-Interface') install.
icons class compile: 'assetDirectory
 ^ ExperimentRoot / ''assets'' / ''icons'' / ''lucide'' / ''icons'''.
icons class compile: 'iconNamed: name
 ^ self iconNamed: name size: 16 color: (Color gray: 0.45)'.
icons class compile: 'iconNamed: name size: size color: color
 | file svg icon strokeWidth viewBox |
 (name isString and: [ name notEmpty and: [
  name allSatisfy: [ :character | ''abcdefghijklmnopqrstuvwxyz0123456789-'' includes: character ] ] ])
   ifFalse: [ self error: ''Invalid Lucide icon name'' ].
 file := self assetDirectory / (name, ''.svg'').
 file exists ifFalse: [ self error: ''Unknown Lucide icon: '', name ].
 svg := (XMLDOMParser parse: file contents usingNamespaces: false validation: false externalEntities: false) root.
 ((svg localName = ''svg'') and: [ (svg attributeAt: ''viewBox'') = ''0 0 24 24'' ])
  ifFalse: [ self error: ''Unsupported Lucide viewBox: '', name ].
 icon := BlElement new size: 24 @ 24; yourself.
 viewBox := 0 @ 0 extent: 24 @ 24.
 strokeWidth := svg attributeAt: ''stroke-width'' ifAbsent: [ ''2'' ].
 svg elementsDo: [ :shape |
  | element width |
  element := BlElement new size: 24 @ 24;
   geometry: (BlSvgPath new svg: (self pathFor: shape) viewbox: viewBox);
   outskirts: BlOutskirts centered; yourself.
  (shape attributeAt: ''fill'' ifAbsent: [ ''none'' ]) = ''none''
   ifFalse: [ element background: color ].
  (shape attributeAt: ''stroke'' ifAbsent: [ ''currentColor'' ]) = ''none'' ifFalse: [
   width := (shape attributeAt: ''stroke-width'' ifAbsent: [ strokeWidth ]) asNumber.
   element border: (BlBorder builder paint: color; width: width; capRound; joinRound; build) ].
  icon addChild: element ].
 ^ BlScalableElement new size: size @ size; fitAll; contentElement: icon; yourself'.
icons class compile: 'pathFor: shape
 ^ shape localName asSymbol caseOf: {
  [ #path ] -> [ shape attributeAt: ''d'' ].
  [ #line ] -> [ ''M '', (shape attributeAt: ''x1''), '' '', (shape attributeAt: ''y1''),
   '' L '', (shape attributeAt: ''x2''), '' '', (shape attributeAt: ''y2'') ].
  [ #polyline ] -> [ ''M '', (shape attributeAt: ''points'') ].
  [ #polygon ] -> [ ''M '', (shape attributeAt: ''points''), '' Z'' ].
  [ #rect ] -> [ self rectPathFor: shape ].
  [ #circle ] -> [ self ellipsePathFor: shape withRadiusX: (self number: ''r'' of: shape) y: (self number: ''r'' of: shape) ].
  [ #ellipse ] -> [ self ellipsePathFor: shape withRadiusX: (self number: ''rx'' of: shape) y: (self number: ''ry'' of: shape) ]
 } otherwise: [ self error: ''Unsupported Lucide shape: '', shape localName ]'.
icons class compile: 'number: key of: shape
 ^ self svgNumber: (shape attributeAt: key ifAbsent: [ ''0'' ])'.
icons class compile: 'svgNumber: source
 (source beginsWith: ''.'') ifTrue: [ ^ (''0'', source) asNumber asFloat ].
 (source beginsWith: ''-.'') ifTrue: [ ^ (''-0'', source allButFirst) asNumber asFloat ].
 ^ source asNumber asFloat'.
icons class compile: 'pair: x y: y
 ^ x asString, '' '', y asString'.
icons class compile: 'ellipsePathFor: shape withRadiusX: rx y: ry
 | x y arc |
 x := self number: ''cx'' of: shape.
 y := self number: ''cy'' of: shape.
 arc := '' A '', (self pair: rx y: ry), '' 0 1 0 ''.
 ^ ''M '', (self pair: x + rx y: y), arc, (self pair: x - rx y: y), arc, (self pair: x + rx y: y), '' Z'''.
icons class compile: 'rectPathFor: shape
 | x y right bottom width height rx ry radii |
 x := self number: ''x'' of: shape. y := self number: ''y'' of: shape.
 width := self number: ''width'' of: shape. height := self number: ''height'' of: shape.
 right := x + width. bottom := y + height.
 rx := (self svgNumber: (shape attributeAt: ''rx'' ifAbsent: [ shape attributeAt: ''ry'' ifAbsent: [ ''0'' ] ])) min: width / 2.
 ry := (self svgNumber: (shape attributeAt: ''ry'' ifAbsent: [ shape attributeAt: ''rx'' ifAbsent: [ ''0'' ] ])) min: height / 2.
 (rx isZero or: [ ry isZero ]) ifTrue: [
  ^ ''M '', (self pair: x y: y), '' H '', right asString, '' V '', bottom asString, '' H '', x asString, '' Z'' ].
 radii := '' A '', (self pair: rx y: ry), '' 0 0 1 ''.
 ^ ''M '', (self pair: x + rx y: y), '' H '', (right - rx) asString,
  radii, (self pair: right y: y + ry), '' V '', (bottom - ry) asString,
  radii, (self pair: right - rx y: bottom), '' H '', (x + rx) asString,
  radii, (self pair: x y: bottom - ry), '' V '', (y + ry) asString,
  radii, (self pair: x + rx y: y), '' Z'''.
'Loom Lucide icons installed'
