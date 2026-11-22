"Xfyun file transcription. Upload requests are signed and attempted once."
| failure provider |
failure := (Error << #LMVoiceProviderError slots: #(#code); package: 'Loom-Voice') install.
failure compile: 'code ^ code'.
failure compile: 'code: value code := value'.
failure class compile: 'raise: code message: message
 ^ self new code: code; messageText: message; signal'.
provider := (Object << #LMXfyun slots: #(#file); package: 'Loom-Voice') install.
provider compile: 'configuration
 | values |
values := [ STONJSON fromString: file contents ] on: Error do: [ :error | nil ].
(values notNil and: [ #(''appId'' ''apiKey'' ''apiSecret'') allSatisfy: [ :key |
 | value |
 value := values at: key ifAbsent: [ nil ].
 value isString and: [ value trimBoth isNotEmpty ] ] ])
 ifFalse: [ LMVoiceProviderError raise: #notConfigured message: ''尚未配置讯飞录音文件转写。'' ].
^ values'.
provider compile: 'file: configurationFile
 file := configurationFile'.
provider compile: 'configured
 ^ [ self configuration. true ] on: LMVoiceProviderError do: [ :error | false ]'.
provider compile: 'formEncoded: value
 | hexadecimal |
hexadecimal := ''0123456789ABCDEF''.
^ String streamContents: [ :stream |
 value asString utf8Encoded do: [ :byte |
  | character |
  character := Character value: byte.
  ((byte between: 48 and: 57) or: [ (byte between: 65 and: 90) or: [
   (byte between: 97 and: 122) or: [ ''*-._'' includes: character ] ] ])
   ifTrue: [ stream nextPut: character ]
   ifFalse: [ byte = 32
    ifTrue: [ stream nextPut: $+ ]
    ifFalse: [ stream nextPut: $%; nextPut: (hexadecimal at: (byte bitShift: -4) + 1);
      nextPut: (hexadecimal at: (byte bitAnd: 15) + 1) ] ] ] ]'.
provider compile: 'queryString: fields
 ^ ''&'' join: (fields keys sorted collect: [ :key |
 (self formEncoded: key), ''='', (self formEncoded: (fields at: key)) ])'.
provider compile: 'signatureFor: query secret: secret
 | hmac |
hmac := HMAC on: SHA1 new.
hmac key: secret utf8Encoded.
^ ZnBase64Encoder new encode: (hmac digestMessage: query utf8Encoded)'.
provider compile: 'networkFailureForUpload: upload
 upload ifTrue: [
 LMVoiceProviderError raise: #uploadUnknown message: ''上传结果不确定，请核对讯飞订单，未自动重传。'' ].
LMVoiceProviderError raise: #queryRetry message: ''暂时无法查询讯飞订单，将继续查询。'''.
provider compile: 'request: endpoint fields: fields entity: entity
 | config parameters query signature upload client payload code status |
config := self configuration.
parameters := fields copy at: ''accessKeyId'' put: (config at: ''apiKey'');
 at: ''dateTime'' put: ((DateAndTime now asUTC asString first: 19), ''+0000''); yourself.
query := self queryString: parameters.
signature := self signatureFor: query secret: (config at: ''apiSecret'').
upload := endpoint = ''upload''.
client := ZnClient new.
[
 [ payload := client
   url: (''https://office-api-ist-dx.iflyaisol.com/v2/'', endpoint, ''?'', query);
   dontFollowRedirects;
   numberOfRetries: 0;
   timeout: (upload ifTrue: [ 180 ] ifFalse: [ 20 ]);
   headerAt: ''signature'' put: signature;
   entity: entity;
   post.
   status := client response statusLine code.
   payload := STONJSON fromString: payload
 ] on: Error do: [ :error | self networkFailureForUpload: upload ].
 ((status between: 200 and: 299) and: [ (payload at: ''code'' ifAbsent: [ '''' ]) asString = ''000000'' ])
  ifTrue: [ ^ payload at: ''content'' ifAbsent: [ nil ] ].
 (status >= 500 or: [ status between: 300 and: 399 ]) ifTrue: [ self networkFailureForUpload: upload ].
 code := (payload at: ''code'' ifAbsent: [ ''unknown'' ]) asString.
 (code size = 6 and: [ code allSatisfy: #isDigit ]) ifFalse: [ code := ''unknown'' ].
 LMVoiceProviderError raise: #providerRejected message: ''讯飞拒绝请求（'', code, ''），请核对服务权限和额度。''
] ensure: [ client close ]'.
provider compile: 'upload: audio signature: nonce
 | config size fields result |
config := self configuration.
size := audio size.
size > (500 * 1024 * 1024) ifTrue: [
 LMVoiceProviderError raise: #tooLarge message: ''转写音频超过500MB。'' ].
fields := Dictionary new at: ''appId'' put: (config at: ''appId''); at: ''signatureRandom'' put: nonce;
 at: ''fileName'' put: ''audio.flac''; at: ''fileSize'' put: size;
 at: ''durationCheckDisable'' put: ''true''; at: ''language'' put: ''autodialect'';
 at: ''eng_smoothproc'' put: ''false''; at: ''eng_colloqproc'' put: ''false''; yourself.
audio binaryReadStreamDo: [ :stream |
 result := self request: ''upload'' fields: fields entity: (ZnStreamingEntity new
  contentType: ZnMimeType applicationOctetStream; contentLength: size; stream: stream; yourself) ].
(result notNil and: [ (result at: ''orderId'' ifAbsent: [ '''' ]) isNotEmpty ]) ifFalse: [
 LMVoiceProviderError raise: #uploadUnknown message: ''讯飞没有返回订单号，请核对控制台订单。'' ].
^ result'.
provider compile: 'query: orderId signature: nonce
 ^ self request: ''getResult''
 fields: (Dictionary new at: ''orderId'' put: orderId; at: ''signatureRandom'' put: nonce; at: ''resultType'' put: ''transfer''; yourself)
 entity: (ZnEntity json: ''{}'')'.
provider compile: 'parseTranscript: value
 | data lattice segments |
[
 data := value isString ifTrue: [ STONJSON fromString: value ] ifFalse: [ value ].
 lattice := data at: ''lattice'' ifAbsent: [ data at: ''lattice2'' ].
 segments := lattice collect: [ :entry | self parseSegment: (entry at: ''json_1best'') ].
 segments := segments reject: [ :each | (each at: ''text'') isEmpty ].
 ^ Dictionary new at: ''segments'' put: segments;
  at: ''text'' put: (String lf join: (segments collect: [ :each | each at: ''text'' ])); yourself
] on: Error do: [ :error |
 LMVoiceProviderError raise: #invalidResult message: ''讯飞转录结果无法解析，原始结果已保留。'' ]'.
provider compile: 'parseSegment: value
 | entry data words text spoken start finish bg ed |
entry := value isString ifTrue: [ STONJSON fromString: value ] ifFalse: [ value ].
data := entry at: ''st''.
words := (data at: ''rt'') flatCollect: [ :part | part at: ''ws'' ].
text := ('''' join: (words collect: [ :word | (self candidateOf: word) at: ''w'' ifAbsent: [ '''' ] ])) trimBoth.
spoken := words select: [ :word |
 | candidate |
 candidate := self candidateOf: word.
 (#(''p'' ''g'') includes: (candidate at: ''wp'' ifAbsent: [ '''' ])) not
  and: [ (candidate at: ''w'' ifAbsent: [ '''' ]) anySatisfy: #isAlphaNumeric ] ].
bg := (data at: ''bg'') asNumber.
ed := (data at: ''ed'') asNumber.
start := bg + (spoken ifEmpty: [ 0 ] ifNotEmpty: [ ((spoken first at: ''wb'' ifAbsent: [ 0 ]) asNumber) * 10 ]).
finish := spoken ifEmpty: [ ed ] ifNotEmpty: [
 (spoken last at: ''we'' ifAbsent: [ nil ]) ifNil: [ ed ] ifNotNil: [ :index | ed min: bg + (index asNumber * 10) ] ].
^ Dictionary new at: ''start'' put: (start / 1000) asFloat; at: ''end'' put: (finish / 1000) asFloat;
 at: ''text'' put: text; yourself'.
provider compile: 'candidateOf: word
 ^ (word at: ''cw'' ifAbsent: [ #() ]) ifEmpty: [ Dictionary new ] ifNotEmpty: [ :items | items first ]'.
'GT Xfyun transcription installed'
