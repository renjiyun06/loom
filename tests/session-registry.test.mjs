import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {EventEmitter} from 'node:events';
import {SessionRegistry} from '../src/bridge/session-registry.mjs';
import {CodexAppServer} from '../src/bridge/codex-app-server.mjs';
import {CodexSettings} from '../src/bridge/codex-settings.mjs';
import {ActivityFeed} from '../src/bridge/activity-feed.mjs';
import {migrateActivities} from '../src/bridge/activity-store.mjs';
import {randomUUID} from 'node:crypto';
import {root} from '../src/bridge/paths.mjs';
import {archivePendingCommands} from '../src/bridge/runtime-client.mjs';
const base=path.join(root,'tests/results/session-registry-unit');
fs.mkdirSync(base,{recursive:true});
function registry(){return new SessionRegistry(fs.mkdtempSync(path.join(base,'case-')));}
test('activity keeps calls and manual session switches in execution order', () => {
  const db = registry();
  db.initializeDefault('old-thread');
  db.beginCall({id:'before',action:'ask',clientKey:'default',prompt:'private input'});
  db.completeCall('before',{ok:true,threadId:'old-thread'});
  const reset={id:'switch',action:'newConversation',clientKey:'default'};
  db.explicitReset(reset);
  db.explicitReset(reset);
  db.beginCall({id:'after',action:'ask',clientKey:'another-program'});
  db.activity.accept('after',{method:'item/started',params:{item:{id:'tool',type:'dynamicToolCall',tool:'fixture',arguments:{token:'secret'}}}});
  const during = db.activity.page({limit:10}).items;
  assert.deepEqual(during.map(row=>row.id), ['before/summary','switch/summary','after/tool']);
  assert.equal(db.get('default').generation,1);
  assert.equal(during.at(-1).status,'inProgress');
  assert.equal(during.at(-1).arguments.token,'[已隐藏]');
  assert.doesNotMatch(JSON.stringify(during), /private input/);
  db.completeCall('after',{ok:false});
  assert.equal(db.activity.page({limit:10}).items.find(row=>row.id==='after/tool').status,'interrupted');
  db.close();
});
test('old bridge events and Codex rollout import once into the same ordered activity table', () => {
  const db=registry();
  db.initializeDefault('old-thread');
  const folder=path.dirname(db.file);
  const logs=path.join(folder,'logs');
  const codexHome=path.join(folder,'codex');
  fs.mkdirSync(path.join(logs,'codex-events'),{recursive:true});
  fs.mkdirSync(path.join(codexHome,'sessions'),{recursive:true});
  const old=db.db.prepare("INSERT INTO calls VALUES (?,'completed',?,?)");
  old.run('old',JSON.stringify({action:'ask'}),JSON.stringify({ok:true,threadId:'old-thread',turnId:'old-turn'}));
  old.run('recent',JSON.stringify({action:'ask'}),JSON.stringify({ok:true}));
  fs.writeFileSync(path.join(codexHome,'sessions','rollout-old-thread.jsonl'),JSON.stringify({type:'event_msg',
    payload:{type:'item_completed',turn_id:'old-turn',item:{id:'old-note',type:'AgentMessage',phase:'commentary',content:[{text:'older'}]}}})+'\n');
  fs.writeFileSync(path.join(logs,'codex-events','recent.events.jsonl'),JSON.stringify({direction:'server',
    message:{method:'item/completed',params:{item:{id:'recent-note',type:'agentMessage',phase:'commentary',text:'recent'}}}})+'\n');
  assert.equal(migrateActivities(db,{logs,codexHome}),true);
  assert.equal(migrateActivities(db,{logs,codexHome}),false);
  assert.deepEqual(db.activity.page({limit:10}).items.map(row=>[row.id,row.text]),
    [['old/old-note','older'],['recent/recent-note','recent']]);
  db.close();
});
test('live updates and history pages come from the same activity table', () => {
  const db=registry();
  const feed=new ActivityFeed(path.dirname(db.file),db.activity);
  const view=randomUUID(), focus=randomUUID();
  const request=(serial,limit)=>{
    fs.writeFileSync(path.join(feed.inbox,randomUUID()+'.json'),JSON.stringify({view,serial,limit,focus}));
    feed.poll();
    return JSON.parse(fs.readFileSync(feed.output,'utf8'));
  };
  db.activity.record('first','one');
  db.activity.record('second','two');
  db.activity.accept(focus,{method:'item/started',params:{item:{id:'note',type:'agentMessage',phase:'commentary',text:'A'}}});
  assert.deepEqual(request(1,2).items.map(row=>row.id),['second/summary',focus+'/note']);
  db.activity.accept(focus,{method:'item/agentMessage/delta',params:{itemId:'note',delta:'B'}});
  db.activity.accept(focus,{method:'item/started',params:{item:{id:'answer',type:'agentMessage',phase:'final_answer',text:'response'}}});
  db.activity.record('third','three');
  feed.poll();
  const live=JSON.parse(fs.readFileSync(feed.output,'utf8'));
  assert.equal(live.answer,'response');
  assert.deepEqual(live.items.map(row=>row.id),['second/summary',focus+'/note','third/summary']);
  assert.equal(live.items[1].text,'AB');
  assert.deepEqual(request(2,4).items.map(row=>row.id),['first/summary','second/summary',focus+'/note','third/summary']);
  db.close();
});
test('bridge routes live activity to SQLite using the active call and turn', () => {
  const db=registry();
  const server=Object.assign(new EventEmitter(),{sessionRegistry:db,
    active:{requestId:'active-call',threadId:'active-thread',turnId:'active-turn'}});
  const send=turnId=>CodexAppServer.prototype.receive.call(server,{method:'item/completed',params:{
    threadId:'active-thread',turnId,item:{id:'note',type:'agentMessage',phase:'commentary',text:turnId}}});
  send('old-turn');
  send('active-turn');
  assert.deepEqual(db.activity.page({limit:10}).items.map(({id,text})=>[id,text]),[['active-call/note','active-turn']]);
  db.close();
});
test('session overview and conversation independently stream, filter, and page the same activities', () => {
  const db=registry();
  try {
    db.initializeDefault('legacy-thread');
    const research=db.registerLoomSession('research');
    const activity=(clientKey,title)=>{
      const id=randomUUID();
      db.beginCall({id,clientKey,action:'ask'});
      db.activity.record(id,title);
      return id;
    };
    activity('default','old dialogue');
    activity(research.clientKey,'old research');
    const conversationCall=activity('default','current dialogue');
    activity('probe','temporary verification');
    const researchCall=activity(research.clientKey,'current research');
    db.activity.accept(conversationCall,{method:'item/completed',params:{
      item:{id:'answer',type:'agentMessage',phase:'final_answer',text:'live reply'},
    }});
    const detachedSwitch=randomUUID();
    db.log('default','explicit-new-conversation',1,'legacy-thread',detachedSwitch);
    db.activity.record(detachedSwitch,'session switch');
    const feed=new ActivityFeed(path.dirname(db.file),db.activity);
    const conversation=randomUUID(),overview=randomUUID();
    function request(channel,view,serial,limit,session,focus=null){
      fs.writeFileSync(path.join(feed.inbox,randomUUID()+'.json'),
        JSON.stringify({channel,view,serial,limit,session,focus}));
    }
    const conversationPage=()=>JSON.parse(fs.readFileSync(feed.output,'utf8'));
    const overviewPage=()=>JSON.parse(fs.readFileSync(feed.overview,'utf8'));
    request('conversation',conversation,1,2,'main',conversationCall);
    request('overview',overview,1,4,null);
    feed.poll();
    assert.equal(conversationPage().answer,'live reply');
    assert.deepEqual(conversationPage().items.map(row=>row.title),['current dialogue','session switch']);
    assert.deepEqual(overviewPage().items.map(row=>row.sessionId),['research','main','research','main']);
    assert.ok(!overviewPage().items.some(row=>row.title==='temporary verification'));
    request('overview',overview,2,1,'research',conversationCall);
    feed.poll();
    assert.equal(overviewPage().answer,'');
    assert.deepEqual(overviewPage().items.map(row=>row.id),[researchCall+'/summary']);
    assert.equal(overviewPage().older,true);
    activity(research.clientKey,'new research');
    request('overview',overview,3,2,'research');
    feed.poll();
    assert.deepEqual(overviewPage().items.map(row=>row.title),['old research','current research','new research']);
    assert.deepEqual(conversationPage().items.map(row=>row.title),['current dialogue','session switch']);
    assert.equal(conversationPage().serial,1);
  } finally {db.close();}
});
test('Codex settings select a tier explicitly and reject unavailable combinations', () => {
  const dir = fs.mkdtempSync(path.join(base,'settings-'));
  const file = path.join(dir,'codex.json');
  const cache = path.join(dir,'models.json');
  const defaults={model:'gpt-6.2-sol',effort:'high',fast:true};
  fs.writeFileSync(file,JSON.stringify(defaults));
  fs.writeFileSync(cache,JSON.stringify({models:[{slug:defaults.model,display_name:'GPT-6.2-Sol',
    visibility:'list',supported_reasoning_levels:[{effort:'high'},{effort:'medium'}],service_tiers:[{id:'priority'}]}]}));
  const settings=new CodexSettings(file,cache);
  assert.deepEqual(settings.turnParams(),{model:'gpt-6.2-sol',effort:'high',serviceTier:'priority'});
  settings.save({...defaults,effort:'medium',fast:false});
  assert.deepEqual(settings.turnParams(),{model:'gpt-6.2-sol',effort:'medium',serviceTier:'default'});
  assert.throws(()=>settings.save({...defaults,effort:'unknown'}),/不可用/);
  assert.equal(settings.current().effort,'medium');
});
test('old image cannot overwrite a binding committed after the image',()=>{
  const db=registry();const directory=path.dirname(db.file);
  db.initializeDefault('old-image-thread');db.reset('default','explicit-reset');
  db.beginCreate('default','new-request');db.bindCreated('default','new-request','new-durable-thread');db.close();
  const reopened=new SessionRegistry(directory);
  assert.equal(reopened.initializeDefault('old-image-thread').threadId,'new-durable-thread');reopened.close();
});
test('explicit new conversation survives loss of the old image cache',()=>{
  const db=registry();const directory=path.dirname(db.file);
  db.initializeDefault('prior-thread');db.reset('default','explicit-reset');db.close();
  const reopened=new SessionRegistry(directory);const binding=reopened.initializeDefault('prior-thread');
  assert.equal(binding.state,'unbound');assert.equal(binding.threadId,null);assert.equal(binding.generation,1);reopened.close();
});
test('unresolved remote creation is never automatically repeated',()=>{
  const db=registry();db.initializeDefault(null);db.beginCreate('default','uncertain-request');
  assert.throws(()=>db.beginCreate('default','retry'),/refusing a new conversation/);db.close();
});
test('missing known registry blocks startup instead of replacing it',()=>{
  const db=registry();const directory=path.dirname(db.file);const file=db.file;db.close();
  fs.renameSync(file,file+'.saved');assert.throws(()=>new SessionRegistry(directory),/refusing to create replacement/);
});
test('abandoned commands cannot replay a previous explicit reset',()=>{
  const directory=fs.mkdtempSync(path.join(base,'mailbox-'));
  fs.mkdirSync(path.join(directory,'mailbox'));
  fs.writeFileSync(path.join(directory,'mailbox/old-reset.st'),'PharoCodex newConversation');
  assert.equal(archivePendingCommands(directory),1);
  assert.equal(fs.readdirSync(path.join(directory,'mailbox')).length,0);
  assert.equal(JSON.parse(fs.readFileSync(path.join(directory,'results/old-reset.json'),'utf8')).error,'RUNTIME_INTERRUPTED');
});
function fakeServer(registry,request) {
  const server=Object.assign(new EventEmitter(),{sessionRegistry:registry,active:null,loadedThreads:new Set(),threadModels:new Map(),cwd:root,
    request,dead:null});
  server.call=CodexAppServer.prototype.call;return server;
}
const input={id:'test-request',clientKey:'default',threadId:null,prompt:'test',timeoutSeconds:1};
test('failed resume does not fall back to thread/start',async()=>{
  const db=registry();db.initializeDefault('original-thread');const methods=[];
  const server=fakeServer(db,async method=>{methods.push(method);throw new Error('cannot restore');});
  const result=await server.call(input);
  assert.equal(result.ok,false);assert.deepEqual(methods,['thread/resume']);assert.equal(db.get('default').threadId,'original-thread');db.close();
});
test('pending creation does not dispatch another thread/start',async()=>{
  const db=registry();db.initializeDefault(null);db.beginCreate('default','first');const methods=[];
  const server=fakeServer(db,async method=>{methods.push(method);throw new Error('unexpected');});
  const result=await server.call(input);assert.equal(result.ok,false);assert.deepEqual(methods,[]);db.close();
});
test('new binding is committed before any turn/start request',async()=>{
  const db=registry();db.initializeDefault(null);const methods=[];
  const server=fakeServer(db,async(method,params,timeout,onResult)=>{
    methods.push(method);
    if(method==='thread/start'){const result={thread:{id:'created-thread'},model:'test'};onResult(result);return result;}
    if(method==='thread/name/set')return {};
    if(method==='turn/start'){assert.equal(db.get('default').threadId,'created-thread');throw new Error('simulate interruption before turn');}
  });
  const result=await server.call(input);assert.equal(result.ok,false);assert.equal(db.get('default').threadId,'created-thread');
  assert.deepEqual(methods,['thread/start','thread/name/set','turn/start']);db.close();
});
test('a completed invocation survives reopening and returns the original receipt',()=>{
 const db=registry();const directory=path.dirname(db.file);db.initializeDefault('thread');
 const request={id:'receipt',clientKey:'default'};db.beginCall(request);db.completeCall('receipt',{ok:true,text:'answer',id:'receipt'});db.close();
 const reopened=new SessionRegistry(directory);assert.deepEqual(reopened.callResult('receipt'),{ok:true,text:'answer',id:'receipt'});reopened.close();
});
test('an interrupted invocation is reported uncertain, never treated as not yet sent',()=>{
 const db=registry();db.initializeDefault('thread');db.beginCall({id:'unknown',clientKey:'default'});
 const result=db.callResult('unknown');assert.equal(result.ok,false);assert.match(result.error,/not sent again/);db.close();
});
test('replaying an explicit reset receipt does not switch the conversation twice',()=>{
 const db=registry();db.initializeDefault('thread');const request={id:'reset-once',clientKey:'default'};
 const first=db.explicitReset(request);const second=db.explicitReset(request);
 assert.deepEqual(second,first);assert.equal(db.get('default').generation,1);db.close();
});
