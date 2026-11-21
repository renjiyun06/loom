"Windows IME integration for GT's Winit30/Brick editors."
| bridge |
bridge := (Object << #LMWindowsIme slots: #(); package: 'Loom-Interface') install.
bridge compile: 'positionWindow: hwnd x: x y: y width: width height: height
 ^ self ffiCall: #(uint64 loom_ime_set_cursor(void* hwnd, int32 x, int32 y, int32 width, int32 height))
  module: (ExperimentRoot / ''runtime'' / ''windows-ime'' / ''LoomWindowsIme.dll'') fullName options: #(optEventLoop)'.
bridge compile: 'position: rectangle window: hwnd
 ^ (self positionWindow: hwnd x: rectangle left rounded y: rectangle top rounded
  width: (rectangle width ceiling max: 1) height: (rectangle height ceiling max: 1)) = 7'.
bridge compile: 'updateForHost: host force: force
 | focus cursor rectangle cacheKey |
 host space isFocused ifFalse: [ ^ self ].
 focus := host space focusOwner.
 focus ifNil: [ ^ self ].
 cursor := nil.
 focus withAllChildrenBreadthFirstDo: [ :element |
  (cursor isNil and: [ element isKindOf: BrCursorElement ]) ifTrue: [ cursor := element ] ].
 (cursor isNil or: [ cursor isAttachedToSceneGraph not ]) ifTrue: [ ^ self ].
 rectangle := cursor boundsInWindow.
 rectangle height <= 0 ifTrue: [ ^ self ].
 cacheKey := { focus. rectangle }.
 (force or: [ (host space root userData at: #loomImeAnchor ifAbsent: [ nil ]) ~= cacheKey ]) ifTrue: [
  (self position: rectangle window: host window hwnd) ifTrue: [
   host space root userData at: #loomImeAnchor put: cacheKey ] ].
 ^ self'.
Smalltalk globals at: #LoomWindowsIme put: bridge new.
BlWinit30HostSpace compile: 'visitKeyboardInputEvent: anEvent
 "VK_PROCESSKEY belongs to the IME. Its key-up may name another key;
  buffering it as Unknown leaves a permanently pressed key and breaks shortcuts."
 (anEvent keyType = Winit30KeyType NamedType and: [ anEvent namedKey = Winit30NamedKey ProcessKey ])
  ifTrue: [ LoomWindowsIme updateForHost: self force: true. ^ self ].
 (KeyboardInputModifiersToIgnore includes: anEvent key) ifTrue: [ ^ self ].
 super visitKeyboardInputEvent: anEvent'.
BlWinit30HostSpace compile: 'generateEvents
 super generateEvents.
 [ LoomWindowsIme updateForHost: self force: false ]
  on: Error do: [ :error | Smalltalk globals at: #LoomImeLastError put: error messageText ]'.
'Windows IME installed'
