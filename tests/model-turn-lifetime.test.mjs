import test from 'node:test';
import assert from 'node:assert/strict';
import {EventEmitter} from 'node:events';
import {setImmediate as nextTick} from 'node:timers/promises';
import fs from 'node:fs';
import {CodexAppServer} from '../src/bridge/codex-app-server.mjs';

function serverFixture() {
  const server = new EventEmitter();
  Object.setPrototypeOf(server, CodexAppServer.prototype);
  Object.assign(server, {
    cwd: 'fixture', active: null,
    pending: new Map(), loadedThreads: new Set(['thread-existing']),
    threadModels: new Map([['thread-existing', 'fixture-model']]),
    sessionRegistry: {ensureClient() {return {threadId: 'thread-existing', state: 'bound'};}},
    calls: [],
  });
  server.request = async function(method, params) {
    this.calls.push({method, params});
    if (method === 'turn/start') return {turn: {id: 'turn-existing'}};
    if (method === 'turn/interrupt') {
      queueMicrotask(() => this.emit('notification', {
        method: 'turn/completed', params: {threadId: 'thread-existing',
          turn: {id: 'turn-existing', status: 'interrupted', items: []}},
      }));
      return {};
    }
    throw new Error('Unexpected request: ' + method);
  };
  return server;
}
const request = {id:'request-existing', clientKey:'default', prompt:'fixture', timeoutSeconds:600};

test('only runtime_eval can execute Smalltalk from an active turn', async () => {
  const server=serverFixture();
  server.active={threadId:'thread-existing',turnId:'turn-existing'};
  const sent=[];
  const evaluated=[];
  server.send=message=>sent.push(message);
  server.evaluateTool=async code=>{evaluated.push(code);return {ok:true,value:4};};
  const params={threadId:'thread-existing',turnId:'turn-existing',arguments:{code:'2 + 2'}};
  await server.handleServerRequest({id:1,method:'item/tool/call',params:{...params,tool:'pharo_eval'}});
  await server.handleServerRequest({id:2,method:'item/tool/call',params:{...params,tool:'runtime_eval'}});
  assert.deepEqual(evaluated,['2 + 2']);
  assert.deepEqual(sent.map(({id,result})=>[id,result.success]),[[1,false],[2,true]]);
});

test('a model turn survives 24 hours of simulated time, then completes once', async t => {
  t.mock.timers.enable({apis:['setTimeout']});
  const server = serverFixture();
  let settled = false;
  const pending = server.call(request).then(r => { settled = true; return r; });
  await nextTick();
  assert.equal(server.active.turnId, 'turn-existing');
  t.mock.timers.tick(24 * 60 * 60 * 1000);
  await nextTick();
  assert.equal(settled, false);
  assert.equal(server.calls.some(c => c.method === 'turn/interrupt'), false);
  server.emit('notification', {method:'turn/completed', params:{
    threadId:'thread-existing', turn:{id:'turn-existing', status:'completed',
      items:[{type:'agentMessage', id:'answer', phase:'final_answer', text:'done'}]},
  }});
  const result = await pending;
  assert.equal(result.ok, true);
  assert.equal(result.text, 'done');
  assert.equal(result.threadId, 'thread-existing');
  assert.equal(server.active, null);
  assert.equal(server.listenerCount('notification'), 0);
  assert.equal(server.listenerCount('failure'), 0);
});

test('explicit cancellation still settles the same turn', async () => {
  const server = serverFixture();
  const pending = server.call({...request, timeoutSeconds:null});
  await nextTick();
  await server.interrupt();
  const result = await pending;
  assert.equal(result.ok, false);
  assert.match(result.error, /interrupted/);
  assert.ok(server.calls.some(c => c.method === 'turn/interrupt' && c.params.turnId === 'turn-existing'));
  assert.equal(server.calls.some(c => c.method === 'thread/start'), false);
  assert.equal(server.active, null);
  assert.equal(server.listenerCount('notification'), 0);
});

test('a completed object call waits for the result checkpoint and needs no text answer', async () => {
  const server=serverFixture();
  let settled=false;
  const pending=server.call({...request,objectInvocation:true}).then(result=>{settled=true;return result;});
  await nextTick();
  let saved;
  server.active.objectSave=new Promise(resolve=>{saved=resolve;});
  server.emit('notification',{method:'turn/completed',params:{
    threadId:'thread-existing',turn:{id:'turn-existing',status:'completed',items:[]},
  }});
  await nextTick();
  assert.equal(settled,false);
  saved('checkpoint-id');
  const result=await pending;
  assert.equal(result.ok,true);
  assert.equal(result.text,'');
});

test('a text-only answer cannot complete a GT object invocation', async () => {
  const server=serverFixture();
  const pending=server.call({...request,objectInvocation:true});
  await nextTick();
  server.emit('notification',{method:'turn/completed',params:{
    threadId:'thread-existing',turn:{id:'turn-existing',status:'completed',
      items:[{type:'agentMessage',id:'answer',phase:'final_answer',text:'Unsubmitted answer'}]},
  }});
  const result=await pending;
  assert.equal(result.ok,false);
  assert.match(result.error,/without returning a GT object/);
});
test('a resumed thread takes the selected model, effort, and tier on the next turn', async () => {
  const server = serverFixture();
  const overrides={model:'gpt-6.2-sol',effort:'high',serviceTier:'priority'};
  const pending = server.call(request, overrides);
  await nextTick();
  const {model,effort,serviceTier}=server.calls.find(call=>call.method==='turn/start').params;
  assert.deepEqual({model,effort,serviceTier},overrides);
  await server.interrupt();
  await pending;
});

test('a corrected recording cannot start a turn in a different Codex thread', async () => {
  const server=serverFixture();
  const result=await server.call({...request,objectInvocation:true,requiredThreadId:'thread-before-switch'});
  assert.equal(result.ok,false);
  assert.match(result.error,/底层 Codex 会话已切换/);
  assert.deepEqual(server.calls,[]);
});

test('transport failure settles immediately without retrying or starting a new thread', async () => {
  const server = serverFixture();
  const pending = server.call({...request, timeoutSeconds:undefined});
  await nextTick();
  server.fail(new Error('fixture transport failure'));
  const result = await pending;
  assert.equal(result.ok, false);
  assert.match(result.error, /fixture transport failure/);
  assert.equal(server.calls.some(c => c.method === 'turn/interrupt'), false);
  assert.deepEqual(server.calls.map(c => c.method), ['turn/start']);
});

test('client and ingress have no fixed model deadline', () => {
  const client = fs.readFileSync(new URL('../src/runtime/codex-client.st', import.meta.url),'utf8');
  const ingress = fs.readFileSync(new URL('../src/bridge/serve-codex.mjs', import.meta.url),'utf8');
  const bridge = fs.readFileSync(new URL('../src/bridge/codex-app-server.mjs', import.meta.url),'utf8');
  assert.doesNotMatch(client, /deadline|Codex request timed out|at: ''timeoutSeconds'' put:/);
  assert.doesNotMatch(bridge, /Codex turn timed out|request\.timeoutSeconds/);
  assert.doesNotMatch(ingress, /request\.timeoutSeconds/);
  assert.match(client, /timeoutSeconds := nil/);
  assert.match(bridge, /this\.once\('failure',rejectOnFailure\)/);
  assert.match(ingress, /codex-cancel/);
});
