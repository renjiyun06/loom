"Model settings owned by Loom."
| settings |
settings := (Object << #LMNativeCodexSettings slots: #(#file #catalog); package: 'Loom-Codex') install.
(settings includesSelector: #initializeAt:cache:) ifTrue: [ settings removeSelector: #initializeAt:cache: ].
settings compile: 'initializeAt: configuration
 file := configuration. catalog := #()'.
settings compile: 'models: models
 catalog := models'.
settings compile: 'current
 ^ STONJSON fromString: file contents'.
settings compile: 'options
 | current models |
current := self current.
models := (catalog reject: [ :model | model at: ''hidden'' ifAbsent: [ false ] ]) collect: [ :model |
 | tiers efforts |
 tiers := model at: ''serviceTiers'' ifAbsent: [ #() ].
 efforts := (model at: ''supportedReasoningEfforts'' ifAbsent: [ #() ]) collect: [ :level | level at: ''reasoningEffort'' ].
 Dictionary new at: ''id'' put: (model at: ''model''); at: ''label'' put: (model at: ''displayName'');
  at: ''efforts'' put: efforts; at: ''defaultEffort'' put: (model at: ''defaultReasoningEffort'' ifAbsent: [ nil ]);
  at: ''fast'' put: ((tiers anySatisfy: [ :tier | (tier at: ''id'') = ''priority'' ]) or: [
   (model at: ''additionalSpeedTiers'' ifAbsent: [ #() ]) includes: ''fast'' ]); yourself ].
(models anySatisfy: [ :model | (model at: ''id'') = (current at: ''model'') ]) ifFalse: [
 models := { Dictionary new at: ''id'' put: (current at: ''model''); at: ''label'' put: (current at: ''model'');
  at: ''efforts'' put: { current at: ''effort'' }; at: ''defaultEffort'' put: (current at: ''effort'');
  at: ''fast'' put: (current at: ''fast''); yourself }, models ].
^ Dictionary new at: ''models'' put: models; at: ''current'' put: current; yourself'.
settings compile: 'save: value
 | model fast |
fast := value at: ''fast'' ifAbsent: [ nil ].
model := ((self options at: ''models'') detect: [ :entry | (entry at: ''id'') = (value at: ''model'' ifAbsent: [ nil ]) ] ifNone: [ nil ]).
(model notNil and: [ (fast = true or: [ fast = false ]) and: [
 ((model at: ''efforts'') includes: (value at: ''effort'' ifAbsent: [ nil ])) and: [
  fast not or: [ model at: ''fast'' ] ] ] ])
 ifFalse: [ self error: ''此模型、思考强度与 Fast 的组合不可用'' ].
LMPlatformTools writeJSON: (Dictionary new at: ''model'' put: (value at: ''model'');
 at: ''effort'' put: (value at: ''effort''); at: ''fast'' put: fast; yourself) to: file.
^ self options'.
settings compile: 'turnParams
 | current model effort fast |
current := self current.
model := current at: ''model''.
effort := current at: ''effort''.
fast := current at: ''fast''.
(model isString and: [ model isNotEmpty and: [ effort isString and: [ effort isNotEmpty and: [ fast = true or: [ fast = false ] ] ] ] ])
 ifFalse: [ self error: ''Loom Codex 配置格式无效'' ].
^ Dictionary new at: ''model'' put: model; at: ''effort'' put: effort;
 at: ''serviceTier'' put: (fast ifTrue: [ ''priority'' ] ifFalse: [ ''default'' ]); yourself'.
'GT Codex settings installed'
