import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {root,paths} from '../src/bridge/paths.mjs';
import {evaluate} from '../src/bridge/runtime-client.mjs';

test('portable distribution matches the verified official release',()=>{
 const release=JSON.parse(fs.readFileSync(path.join(root,'config/gtoolkit-release.json'),'utf8'));
 assert.equal(release.tag,'v1.1.699');
 assert.equal(release.prerelease,false);
 const zip=fs.readFileSync(path.join(root,'downloads',release.asset));
 assert.equal('sha256:'+createHash('sha256').update(zip).digest('hex'),release.digest);
});

test('live GT matches the durable session binding and local voice configuration',async()=>{
 const reply=await evaluate(`{
  GtImage version asString. ExperimentRoot fullName. LoomCodex threadId.
  (LMVoice index at: 'configured').
  LoomConversation records size.
 }`,'loom-contract');
 assert.equal(reply.ok,true,JSON.stringify(reply));
 const [version,directory,thread,voice,messages]=reply.value;
 assert.match(version,/v1\.1\.699/);
 assert.equal(directory,root);
 const registry=new DatabaseSync(path.join(root,'state/bridge/sessions.sqlite'),{readOnly:true});
 try{assert.equal(thread,registry.prepare('SELECT thread_id FROM bindings WHERE client_key=?').get('default').thread_id);}
 finally{registry.close();}
 assert.equal(voice,true);
 assert.ok(Number.isInteger(messages)&&messages>=0);
});

test('preserved audio and local credentials remain inside the environment',()=>{
 for(const entry of fs.readdirSync(path.join(root,'state/audio'),{withFileTypes:true}).filter(e=>e.isDirectory())){
  const directory=path.join(root,'state/audio',entry.name);
  if(fs.existsSync(path.join(directory,'message.json')))assert.ok(fs.readdirSync(directory).some(n=>/^original\./.test(n)));
 }
 assert.ok(fs.existsSync(path.join(root,'config/xfyun.local.json')));
});

test('GT sends one tagged transcript message with its original ID and keeps audio storage private',async()=>{
 const result=await evaluate(`| queued failed silent ready input message voice |
  queued := Dictionary new at: 'state' put: 'processing'; yourself.
  failed := Dictionary new at: 'state' put: 'failed'; at: 'error' put: 'recognizer error'; yourself.
  silent := Dictionary new at: 'state' put: 'completed'; at: 'transcript' put: ' '; yourself.
  ready := Dictionary new at: 'state' put: 'completed'; at: 'transcript' put: ' synthetic result '; yourself.
  input := Dictionary new at: 'id' put: 'message-1'; at: 'audioId' put: 'internal-audio-id'; at: 'text' put: ''; yourself.
  voice := LMVoice transcribedText: ready.
  message := LoomConversation recordingMessage: input transcript: voice.
  { (LMVoice transcribedText: queued) isEmpty.
    (LMVoice transcribedText: failed) isEmpty.
    (LMVoice transcribedText: silent) isEmpty.
    LMVoice transcriptionStatus: failed.
    message at: 'id'. message at: 'kind'. message at: 'text'.
    (message includesKey: 'audioId') not. input includesKey: 'audioId' }`,'voice-message-payload');
 assert.deepEqual(result,{ok:true,value:[true,true,true,'recognizer error','message-1','audio','synthetic result',true,true]});
});

test('GT stores a speech correction once and carries the same thread into its reply',async()=>{
 const directory=path.join(root,'tests/results','speech-correction-'+randomUUID());
 fs.mkdirSync(directory,{recursive:true});
 const literal="'"+directory.replaceAll("'","''")+"'";
 const source=String.raw`| conversationClass sessionClass conversation result input session |
  conversationClass := LMConversation newAnonymousSubclass.
  conversationClass compile: 'directory ^ ', ${literal} storeString, ' asFileReference'.
  conversationClass compile: ((LMConversation >> #answer:) sourceCode
   copyReplaceAll: 'session := LoomCodex session: #main.' with: 'session := self probeSession.').
  sessionClass := Object newAnonymousSubclass.
  sessionClass compile: 'requireThread: expected during: operation
   expected ifNotNil: [ expected = ''same-thread'' ifFalse: [ self error: ''Thread mismatch'' ] ].
   ^ operation value'.
  sessionClass compile: 'correctSpeechTranscript: text
   text = ''ROM'' ifFalse: [ self error: ''Expected original transcript'' ].
   ^ ''Loom'''.
  sessionClass compile: 'lastResponse ^ Dictionary new at: ''threadId'' put: ''same-thread''; yourself'.
  sessionClass compile: 'replyTo: message usingContext: context
   ((message at: ''kind'') = ''audio'' and: [ (message at: ''text'') = ''Loom'' and: [ context = ''Loom'' ] ])
    ifFalse: [ self error: ''Corrected audio message was not delivered'' ].
   ^ ''done'''.
  session := sessionClass new.
  conversationClass compile: 'probeSession ^ Smalltalk globals at: #LoomSpeechTestSession'.
  Smalltalk globals at: #LoomSpeechTestSession put: session.
  [ conversation := conversationClass new.
   input := Dictionary new at: 'id' put: 'fixture'; at: 'kind' put: 'audio'; at: 'text' put: 'ROM'; yourself.
   result := conversation answer: input.
   sessionClass compile: 'correctSpeechTranscript: text self error: ''Correction was called twice'''.
   { result. (conversation speechCorrectionAt: 'fixture') at: 'text'.
     conversation answer: input. input at: 'text' }
  ] ensure: [ Smalltalk globals removeKey: #LoomSpeechTestSession ]`;
 const result=await evaluate(source,'speech-correction-chain');
 assert.deepEqual(result,{ok:true,value:['done','Loom','done','ROM']});
});

test('runtime_eval exposes the native invocation roots and returns the very same GT object',async()=>{
 const requestId=randomUUID();
 const pending=`(LMInvocation pendingAt: '${requestId}')`;
 const setup=await evaluate(`| origin |
  origin := Object newAnonymousSubclass.
  origin compile: 'createProbe: id
   | actual message |
   actual := Object new.
   message := Message selector: #choose:under: arguments: { actual. #rule }.
   LMInvocation new message: message caller: thisContext; attachTo: id'.
  origin new createProbe: '${requestId}'. true`,'setup-runtime-return');
 assert.equal(setup.ok,true,JSON.stringify(setup));
 const tool=code=>evaluate(`${pending} evaluate: [ :loomCaller :loomMessage :loomSessionId :loomReturn |
  ${code} ] sessionId: 'main'`,'gt-invocation-fixture');
 try {
  const inspected=await tool(`{
   loomSessionId. loomMessage class name. loomMessage selector asString.
   loomMessage arguments second asString.
   loomCaller method sourceCode includesSubstring: 'createProbe: id'
  }`);
  assert.deepEqual(inspected,{ok:true,value:[false,['main','Message','choose:under:','rule',true]]});
  const returned=await tool(`
   loomReturn value: loomMessage arguments first.
   loomReturn value: loomMessage arguments first`);
  assert.deepEqual(returned,{ok:true,value:[true,true]});
  const identity=await evaluate(`${pending} result == (${pending} instVarNamed: #message) arguments first`,'verify-runtime-return');
  assert.deepEqual(identity,{ok:true,value:true});
 } finally {
  await evaluate(`${pending} detach. true`,'cleanup-runtime-return');
 }
});
