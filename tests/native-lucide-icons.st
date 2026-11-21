"Check the bundled catalog after changing Lucide or the Bloc conversion."
| files failures result |
files := LMIcons assetDirectory files select: [ :file | file extension = 'svg' ].
failures := OrderedCollection new.
files do: [ :file |
 [ | icon |
  icon := LMIcons iconNamed: file basenameWithoutExtension.
  icon contentElement children ifEmpty: [ self error: 'Empty icon' ]
 ] on: Error do: [ :error | failures add: { file basename. error messageText } ] ].
result := Dictionary new
 at: 'total' put: files size;
 at: 'ok' put: (files notEmpty and: [ failures isEmpty ]);
 at: 'failures' put: failures asArray;
 yourself.
(ExperimentRoot / 'tests' / 'results' / 'conversation-prototype' / 'lucide-library-validation.json')
 ensureCreateFile; writeStreamDo: [ :out | out nextPutAll: (STONJSON toString: result); truncate: out position ].
result
