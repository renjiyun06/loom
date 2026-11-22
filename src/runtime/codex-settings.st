"Model settings owned by Loom."
| settings |
settings := (Object << #LMNativeCodexSettings slots: #(#file #cache); package: 'Loom-Codex') install.
settings compile: 'initializeAt: configuration cache: modelCache
 file := configuration. cache := modelCache'.
settings compile: 'current
 ^ STONJSON fromString: file contents'.
settings compile: 'options
 | current catalog models |
current := self current.
catalog := [ (STONJSON fromString: cache contents) at: ''models'' ifAbsent: [ #() ] ]
 on: Error do: [ :error | #() ].
models := (catalog select: [ :model | (model at: ''visibility'' ifAbsent: [ '''' ]) = ''list'' ]) collect: [ :model |
 | tiers efforts |
 tiers := model at: ''service_tiers'' ifAbsent: [ #() ].
 efforts := (model at: ''supported_reasoning_levels'' ifAbsent: [ #() ]) collect: [ :level | level at: ''effort'' ].
 Dictionary new at: ''id'' put: (model at: ''slug''); at: ''label'' put: (model at: ''display_name'');
  at: ''efforts'' put: efforts; at: ''defaultEffort'' put: (model at: ''default_reasoning_level'' ifAbsent: [ nil ]);
  at: ''fast'' put: (tiers anySatisfy: [ :tier | (tier at: ''id'') = ''priority'' ]); yourself ].
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
