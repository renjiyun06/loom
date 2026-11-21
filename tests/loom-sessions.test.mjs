import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {SessionRegistry} from '../src/bridge/session-registry.mjs';
import {SessionControl,sessionCommand} from '../src/bridge/session-control.mjs';

function fixture(t) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'loom-sessions-'));
  for(const name of ['codex-requests','codex-responses','codex-cancel'])fs.mkdirSync(path.join(dir,name));
  const registry=new SessionRegistry(dir);
  registry.initializeDefault('legacy-thread');
  t.after(()=>{registry.close();fs.rmSync(dir,{recursive:true,force:true});});
  return {registry,dir};
}

test('schema upgrade promotes the default binding and preserves its Codex history', t=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'loom-sessions-upgrade-'));
  const first=new SessionRegistry(dir);
  first.initializeDefault('legacy-thread');
  first.reset('default','switch');
  first.beginCreate('default','create');
  first.bindCreated('default','create','next-thread');
  first.db.prepare("UPDATE bindings SET updated_at='2026-11-22T00:00:00Z' WHERE client_key='default'").run();
  first.db.exec('DROP TABLE loom_sessions; PRAGMA user_version=2;');
  first.close();
  const migrated=new SessionRegistry(dir);
  t.after(()=>{migrated.close();fs.rmSync(dir,{recursive:true,force:true});});
  const session=migrated.loomSession('main');
  assert.equal(session.clientKey,'default');
  assert.equal(session.threadId,'next-thread');
  assert.deepEqual(session.threads.map(row=>[row.threadId,row.current]),[['legacy-thread',false],['next-thread',true]]);
  assert.equal(session.createdAt,session.threads[0].startedAt);
});

test('the former conversation session becomes main with its existing binding and activity', t=>{
  const {registry,dir}=fixture(t);
  const previous={...registry.loomSession('main'),id:'conversation'};
  const analysis=registry.registerLoomSession('analysis');
  registry.beginCall({id:'original-call',clientKey:'default',action:'ask'});
  registry.activity.record('original-call','prior activity');
  registry.db.exec("UPDATE loom_sessions SET id='conversation' WHERE id='main'; PRAGMA user_version=3;");

  const upgraded=new SessionRegistry(dir);
  try {
    assert.deepEqual(upgraded.listLoomSessions(),[{...previous,id:'main'},analysis]);
    assert.equal(upgraded.loomSessionIdForClient('default'),'main');
    assert.equal(upgraded.loomSessionIdForClient(analysis.clientKey),'analysis');
    assert.equal(upgraded.loomSession('conversation'),null);
    const rows=upgraded.activity.page({limit:10,session:'main'}).items;
    assert.deepEqual(rows.map(row=>[row.title,row.sessionId]),[['prior activity','main']]);
  } finally {upgraded.close();}
});

test('named sessions retain their identities and independent histories across reopening', t=>{
  const {registry,dir}=fixture(t);
  const first=registry.registerLoomSession('failureRecovery');
  const other=registry.registerLoomSession('analysis');
  assert.equal(first.clientKey,'loom.failureRecovery');
  assert.deepEqual(registry.registerLoomSession(first.id),first);
  assert.throws(()=>registry.registerLoomSession('bad session'),/Invalid Loom session ID/);
  registry.beginCreate(first.clientKey,'create-1');
  registry.bindCreated(first.clientKey,'create-1','thread-A');
  registry.explicitReset({id:'rotate-1',action:'newConversation',clientKey:first.clientKey});
  registry.beginCreate(first.clientKey,'create-2');
  registry.bindCreated(first.clientKey,'create-2','thread-B');
  const reopened=new SessionRegistry(dir);
  try {
    assert.deepEqual(reopened.listLoomSessions().map(row=>row.id),['main','analysis','failureRecovery']);
    const managed=reopened.loomSession(first.id);
    assert.equal(managed.clientKey,first.clientKey);
    assert.deepEqual(managed.threads.map(row=>[row.threadId,row.current]),[['thread-A',false],['thread-B',true]]);
    assert.deepEqual(reopened.loomSession(other.id),other);
  } finally {reopened.close();}
});

test('management sees in-flight and queued calls and stops only the selected session', t=>{
  const {registry,dir}=fixture(t);
  const first=registry.registerLoomSession('analysis');
  const second=registry.registerLoomSession('publication');
  let active={clientKey:first.clientKey,requestId:randomUUID(),threadId:null,turnId:null};
  const control=new SessionControl({directory:dir,registry,getActive:()=>active});
  function queue(clientKey){
    const id=randomUUID();
    fs.writeFileSync(path.join(dir,'codex-requests',id+'.json'),JSON.stringify({id,clientKey,action:'ask'}));
    return id;
  }
  const publicationCall=queue(second.clientKey);
  const analysisCall=queue(first.clientKey);
  const query=(action,sessionId)=>control.handle({action,sessionId},randomUUID());
  assert.equal(query('show',first.id).runState,'running');
  assert.equal(query('show',second.id).runState,'queued');
  assert.throws(()=>query('rotate',first.id),/pending calls/);
  assert.deepEqual(query('stop',first.id).cancelledRequests,[active.requestId,analysisCall]);
  assert.equal(query('show',first.id).runState,'stopping');
  assert.equal(fs.existsSync(path.join(dir,'codex-cancel',publicationCall+'.json')),false);
  active=null;
  assert.equal(query('rotate',first.id).generation,1);
  assert.equal(query('show',second.id).generation,0);
});

test('a local command receives a snapshot while a turn is still in flight', async t=>{
  const {registry,dir}=fixture(t);
  const active={requestId:randomUUID(),clientKey:'default',threadId:'legacy-thread',turnId:'turn'};
  const control=new SessionControl({directory:dir,registry,getActive:()=>active});
  fs.writeFileSync(path.join(dir,'bridge-ready.json'),JSON.stringify({status:'ready',sessionControl:control.instance}));
  const pending=sessionCommand(dir,'show','main');
  control.poll();
  const session=await pending;
  assert.equal(session.runState,'running');
  assert.deepEqual(session.call,{requestId:active.requestId,threadId:'legacy-thread',turnId:'turn'});
  assert.deepEqual(fs.readdirSync(control.inbox),[]);
  assert.deepEqual(fs.readdirSync(control.outbox),[]);
});
