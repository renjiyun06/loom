"Upgrade the built-in session without reinstalling the saved conversation or its UI."
| source |
#(LoomSessionManagerWindow LoomActivityOverviewWindow) do: [ :key |
 (Smalltalk globals at: key ifAbsent: [ nil ]) ifNotNil: [ :view |
  (view instVarNamed: #selected) = 'conversation' ifTrue: [ view instVarNamed: #selected put: LoomSessions mainId ] ] ].
source := (LMConversation >> #initialize) sourceCode.
(source includesSubstring: 'client := LoomCodex.') ifTrue: [
 LMConversation compile: (source copyReplaceAll: 'client := LoomCodex.' with: 'client := LoomCodex session: #main.') ].
(source includesSubstring: 'LoomCodex session: #conversation') ifTrue: [
 LMConversation compile: (source copyReplaceAll: 'LoomCodex session: #conversation' with: 'LoomCodex session: #main') ].
source := (LMConversation >> #answer:) sourceCode.
(source includesSubstring: '^ client ask: (self preparePrompt: message)') ifTrue: [
 LMConversation compile: (ExperimentRoot / 'src' / 'runtime' / 'conversation-answer.st') contents ].
(source includesSubstring: 'reply := client replyTo:') ifTrue: [
 LMConversation compile: (source copyReplaceAll: 'reply := client replyTo:' with: 'reply := (LoomCodex session: #main) replyTo:') ].
(source includesSubstring: 'LoomCodex session: #conversation') ifTrue: [
 LMConversation compile: (source copyReplaceAll: 'LoomCodex session: #conversation' with: 'LoomCodex session: #main') ].
(Smalltalk globals at: #LMConversationUI ifAbsent: [ nil ]) ifNotNil: [ :ui |
 (ui includesSelector: #collectUpdate) ifTrue: [
  source := (ui >> #collectUpdate) sourceCode.
  (source includesSubstring: 'session: ''conversation''') ifTrue: [
   ui compile: (source copyReplaceAll: 'session: ''conversation''' with: 'session: LoomSessions mainId') ] ] ].
true
