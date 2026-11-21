import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {root,paths} from '../src/bridge/paths.mjs';
import {evaluate} from '../src/bridge/runtime-client.mjs';
import {CodexAppServer} from '../src/bridge/codex-app-server.mjs';

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
 let checkpoints=0;
 const server=Object.assign(Object.create(CodexAppServer.prototype),{
  nextId:1,runtimeDirectory:paths.ipc,
  sessionRegistry:{loomSessionIdForClient:key=>key==='default'?'main':null},
  saveObjectResult:async()=>{checkpoints++;},
 });
 const active={objectInvocation:true,requestId,clientKey:'default'};
 try {
  const inspected=await server.evaluateTool(`{
   loomSessionId. loomMessage class name. loomMessage selector asString.
   loomMessage arguments second asString.
   loomCaller method sourceCode includesSubstring: 'createProbe: id'
  }`,active);
  assert.deepEqual(inspected,{ok:true,value:['main','Message','choose:under:','rule',true]});
  assert.equal(checkpoints,0);
  const returned=await server.evaluateTool(`
   loomReturn value: loomMessage arguments first.
   loomReturn value: loomMessage arguments first`,active);
  assert.deepEqual(returned,{ok:true,value:true});
  assert.equal(checkpoints,1);
  const identity=await evaluate(`${pending} result == (${pending} instVarNamed: #message) arguments first`,'verify-runtime-return');
  assert.deepEqual(identity,{ok:true,value:true});
 } finally {
  await evaluate(`${pending} detach. true`,'cleanup-runtime-return');
 }
});
