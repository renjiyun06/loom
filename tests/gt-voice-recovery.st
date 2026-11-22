"Offline coverage for the GT audio queue. No microphone or network request."
| root manager provider fake id job testAudio verify initial queued performer child lines command out step timer |
root := ExperimentRoot / 'voice-test'.
verify := [ :condition :name | condition ifFalse: [ self error: name ] ].
step := [ :text | LMPlatformTools writeJSON: text to: root / 'test-progress.json' ].
step value: 'recovery'.
#('uploading' 'recording' 'preparing' 'processing') do: [ :phase |
 | record |
 record := Dictionary new at: 'id' put: phase; at: 'title' put: phase;
  at: 'state' put: phase; at: 'original' put: 'original.wav';
  at: 'createdAt' put: DateAndTime now asUTC asString; yourself.
 phase = 'processing' ifTrue: [ record at: 'orderId' put: 'existing-order'; at: 'signatureRandom' put: 'saved-nonce' ].
 LMPlatformTools writeJSON: record to: (root / 'state' / 'audio' / phase / 'message.json') ].
manager := LMGtVoice new initializeAt: root forSession: BridgeRuntimeSessionId; yourself.
verify value: ((manager job: 'uploading') at: 'state') = 'unknown' value: 'uncertain upload remains unknown'.
verify value: ((manager job: 'recording') at: 'state') = 'draft' value: 'capture recovers only a draft'.
verify value: ((manager job: 'preparing') at: 'state') = 'queued' value: 'preparation is safe to resume'.
verify value: ([ manager retry: 'uploading'. false ] on: Error do: [ :error | true ]) value: 'retry cannot repeat an uncertain upload'.
job := manager job: 'uploading'.
job at: 'state' put: 'uploading'.
manager transcriptionError: (Error new messageText: 'connection broke') for: job.
verify value: (job at: 'state') = 'unknown' value: 'an unexpected upload failure stays uncertain'.
provider := LMXfyun new.
verify value: (provider formEncoded: '中 A~*') = '%E4%B8%AD+A%7E*' value: 'form encoding matches the provider signature'.
verify value: (provider signatureFor: 'a=1' secret: 'secret') = '3mJwqfMTFRAxlmL0VuFvy734+Qc=' value: 'HMAC-SHA1 matches the previous implementation'.
initial := '{"lattice":[{"json_1best":{"st":{"bg":"1000","ed":"1600","rt":[{"ws":[{"wb":0,"we":5,"cw":[{"w":"空","wp":"g"}]},{"wb":5,"we":20,"cw":[{"w":"测试","wp":"n"}]},{"wb":20,"we":28,"cw":[{"w":"。","wp":"p"}]}]}]}}}]}'
 copyReplaceAll: '"w":"空"' with: '"w":""'.
out := provider parseTranscript: initial.
verify value: ((out at: 'text') = '测试。'
 and: [ (((out at: 'segments') first at: 'start') closeTo: 1.05)
 and: [ ((out at: 'segments') first at: 'end') closeTo: 1.2 ] ])
 value: 'transcript keeps punctuation and word-relative times'.
fake := LMXfyun newAnonymousSubclass.
fake compile: 'query: orderId signature: nonce
 (orderId = ''existing-order'' and: [ nonce = ''saved-nonce'' ]) ifFalse: [ self error: ''changed order'' ].
 LMVoiceProviderError raise: #queryRetry message: ''temporary error'''.
manager provider: fake new.
job := manager job: 'processing'.
manager query: job.
verify value: (job at: 'state') = 'processing' value: 'transient polling error keeps the same order'.
fake compile: 'query: orderId signature: nonce
 (orderId = ''existing-order'' and: [ nonce = ''saved-nonce'' ]) ifFalse: [ self error: ''changed order'' ].
 ^ Dictionary new at: ''orderInfo'' put: (Dictionary new at: ''status'' put: -1;
  at: ''failType'' put: 6; yourself); yourself'.
manager query: job.
verify value: (job at: 'state') = 'completed' value: 'the original order reaches completion'.
verify value: (manager fileFor: job named: 'provider-result.json') exists value: 'raw provider record is durable'.
queued := manager job: 'recording'.
manager submit: 'recording' message: 'conversation-message'.
verify value: ((queued at: 'state') = 'queued' and: [ (queued at: 'messageId') = 'conversation-message' ])
 value: 'a saved recording is associated with the message'.
performer := (OSEnvironment current at: 'SystemRoot') asFileReference / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'powershell.exe'.
step value: 'interactive Windows command'.
command := '$line=[Console]::ReadLine(); [Console]::WriteLine($line)'.
child := LMPlatformTools interactive: performer arguments: #('-NoProfile' '-Command'), {command}.
manager send: 'voice-fake-control' to: child.
lines := OrderedCollection new.
timer := [ (Delay forSeconds: 8) wait. child isRunning ifTrue: [ child terminate ] ] fork.
[ manager monitor: child lines: [ :line | lines add: line ] ] ensure: [ timer terminate ].
verify value: (lines asArray = #('voice-fake-control') and: [ child wait isSuccess ])
 value: 'Windows child process accepts controls and streams output'.
testAudio := root / 'offline.wav'.
step value: 'native FFmpeg'.
LMPlatformTools run: ExperimentRoot / 'runtime' / 'media' / 'ffmpeg.exe'
 arguments: #('-nostdin' '-v' 'error' '-f' 'lavfi' '-i' 'anullsrc=r=16000:cl=mono' '-t' '0.1'), {testAudio fullName} timeout: 15.
step value: 'GT audio import'.
id := (LMVoice await: (LMVoice request: 'import' options: (Dictionary new at: 'file' put: testAudio fullName; yourself))).
verify value: (id at: 'ok') value: 'GT imports an actual WAV using FFprobe'.
verify value: (((LMVoice job: (id at: 'audioId')) at: 'duration') closeTo: 0.1)
 value: 'native audio import preserves the duration'.
'GT voice recovery passed'
