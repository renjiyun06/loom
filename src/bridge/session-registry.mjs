import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {DatabaseSync} from 'node:sqlite';
import {ActivityStore} from './activity-store.mjs';

export const DEFAULT_LOOM_SESSION='main';

// Independent of the image: commits must finish before a model turn can start.
export class SessionRegistry {
  constructor(directory) {
    fs.mkdirSync(directory,{recursive:true});
    this.file=path.join(directory,'sessions.sqlite');
    const marker=path.join(directory,'registry.json');
    const existed=fs.existsSync(this.file);
    if(fs.existsSync(marker)&&!existed)throw new Error('Session registry is missing; refusing to create replacement conversations');
    this.db=new DatabaseSync(this.file);
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=3000;');
    if(!existed) {
      this.db.exec(`BEGIN IMMEDIATE;
        CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        CREATE TABLE bindings(client_key TEXT PRIMARY KEY,generation INTEGER NOT NULL,
          state TEXT NOT NULL CHECK(state IN ('unbound','creating','bound')),
          thread_id TEXT,request_id TEXT,updated_at TEXT NOT NULL);
        CREATE TABLE events(id INTEGER PRIMARY KEY,client_key TEXT NOT NULL,event TEXT NOT NULL,
          generation INTEGER NOT NULL,thread_id TEXT,request_id TEXT,created_at TEXT NOT NULL);
        PRAGMA user_version=1; COMMIT;`);
      this.db.prepare('INSERT INTO meta VALUES (?,?)').run('installation_id',randomUUID());
    }
    const version=this.db.prepare('PRAGMA user_version').get().user_version;
    if(version===1)this.db.exec("BEGIN IMMEDIATE; CREATE TABLE calls(request_id TEXT PRIMARY KEY,state TEXT NOT NULL,request_json TEXT NOT NULL,result_json TEXT); PRAGMA user_version=2; COMMIT;");
    else if(version!==2&&version!==3&&version!==4)throw new Error('Invalid session registry schema; recovery is required');
    if(version<3)this.db.exec(`BEGIN IMMEDIATE;
      CREATE TABLE loom_sessions(id TEXT PRIMARY KEY,client_key TEXT NOT NULL UNIQUE REFERENCES bindings(client_key),created_at TEXT NOT NULL);
      INSERT INTO loom_sessions
        SELECT 'conversation',client_key,COALESCE(
          (SELECT created_at FROM events WHERE client_key='default' AND event='initialize' ORDER BY id LIMIT 1),updated_at)
        FROM bindings WHERE client_key='default';
      PRAGMA user_version=3; COMMIT;`);
    if(version<4)this.transaction(()=>{
      this.db.prepare("UPDATE loom_sessions SET id=? WHERE id='conversation' AND client_key='default'").run(DEFAULT_LOOM_SESSION);
      this.db.exec('PRAGMA user_version=4');
    });
    this.db.prepare('SELECT client_key FROM bindings LIMIT 1').get();
    const installation=this.db.prepare("SELECT value FROM meta WHERE key='installation_id'").get();
    if(!installation)throw new Error('Session registry identity is missing');
    if(fs.existsSync(marker)) {
      if(JSON.parse(fs.readFileSync(marker,'utf8')).installationId!==installation.value)throw new Error('Session registry identity mismatch');
    } else {
      const fd=fs.openSync(marker,'wx',0o600);
      try {fs.writeFileSync(fd,JSON.stringify({version:1,installationId:installation.value},null,2));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}
    }
    this.activity = new ActivityStore(this.db);
  }
  transaction(fn) {
    this.db.exec('BEGIN IMMEDIATE');
    try{const value=fn();this.db.exec('COMMIT');return value;}catch(error){this.db.exec('ROLLBACK');throw error;}
  }
  validKey(key) {
    if(typeof key!=='string'||!/^[a-zA-Z0-9._-]{1,128}$/.test(key))throw new Error('Invalid conversation client key');
  }
  get(key) {
    this.validKey(key);
    const row=this.db.prepare('SELECT * FROM bindings WHERE client_key=?').get(key);
    if(!row)return null;
    if(row.state==='bound'&&!(typeof row.thread_id==='string'&&row.thread_id.length))throw new Error('Session binding is invalid; recovery is required');
    return {clientKey:row.client_key,generation:row.generation,state:row.state,threadId:row.thread_id,requestId:row.request_id};
  }
  log(key,event,generation,threadId,requestId=null) {
    this.db.prepare('INSERT INTO events(client_key,event,generation,thread_id,request_id,created_at) VALUES (?,?,?,?,?,?)')
      .run(key,event,generation,threadId,requestId,new Date().toISOString());
  }
  initializeDefault(legacyThreadId) {
    return this.transaction(()=>{
      const current=this.get('default');
      if(current)return current;
      if(this.db.prepare("SELECT 1 FROM meta WHERE key='default_initialized'").get())throw new Error('Default conversation binding disappeared; refusing replacement');
      const threadId=legacyThreadId || null;
      this.db.prepare('INSERT INTO bindings VALUES (?,?,?,?,?,?)').run('default',0,threadId?'bound':'unbound',threadId,null,new Date().toISOString());
      this.db.prepare("INSERT INTO meta VALUES ('default_initialized','1')").run();
      this.log('default','initialize',0,threadId);
      this.db.prepare('INSERT INTO loom_sessions VALUES (?,?,?)').run(DEFAULT_LOOM_SESSION,'default',new Date().toISOString());
      return this.get('default');
    });
  }
  ensureClient(key) {
    this.validKey(key);
    const existing=this.get(key);if(existing)return existing;
    if(key==='default')throw new Error('Default conversation binding is missing');
    return this.transaction(()=>this.insertUnboundClient(key));
  }
  insertUnboundClient(key) {
    this.db.prepare('INSERT INTO bindings VALUES (?,?,?,?,?,?)').run(key,0,'unbound',null,null,new Date().toISOString());
    this.log(key,'initialize',0,null);
    return this.get(key);
  }
  validSessionId(id) {
    if(typeof id!=='string'||!/^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$/.test(id))throw new Error('Invalid Loom session ID');
  }
  loomSession(id) {
    this.validSessionId(id);
    const row=this.db.prepare('SELECT client_key,created_at FROM loom_sessions WHERE id=?').get(id);
    if(!row)return null;
    const current=this.get(row.client_key);
    const threads=this.db.prepare(`SELECT generation,thread_id AS threadId,created_at AS startedAt
      FROM events WHERE client_key=? AND (event='bound' OR event='initialize') AND thread_id IS NOT NULL ORDER BY id`)
      .all(row.client_key).map(thread=>({...thread,current:thread.generation===current.generation&&thread.threadId===current.threadId}));
    return {id,createdAt:row.created_at,...current,threads};
  }
  loomSessionIdForClient(clientKey) {
    return this.db.prepare('SELECT id FROM loom_sessions WHERE client_key=?').get(clientKey)?.id ?? null;
  }
  listLoomSessions() {
    return this.db.prepare('SELECT id FROM loom_sessions ORDER BY (id=?) DESC, id').all(DEFAULT_LOOM_SESSION)
      .map(row=>this.loomSession(row.id));
  }
  registerLoomSession(id) {
    this.validSessionId(id);
    return this.transaction(()=>{
      const prior=this.loomSession(id);
      if(prior)return prior;
      if(id===DEFAULT_LOOM_SESSION)throw new Error('Default conversation binding is missing');
      const clientKey='loom.'+id;
      if(!this.get(clientKey))this.insertUnboundClient(clientKey);
      this.db.prepare('INSERT INTO loom_sessions VALUES (?,?,?)').run(id,clientKey,new Date().toISOString());
      return this.loomSession(id);
    });
  }
  beginCreate(key,requestId) {
    return this.transaction(()=>{
      const row=this.get(key);
      if(!row||row.state!=='unbound')throw new Error('A conversation already exists or creation is unresolved; refusing a new conversation');
      this.db.prepare("UPDATE bindings SET state='creating',request_id=?,updated_at=? WHERE client_key=?").run(requestId,new Date().toISOString(),key);
      this.log(key,'creation-started',row.generation,null,requestId);return this.get(key);
    });
  }
  bindCreated(key,requestId,threadId) {
    return this.transaction(()=>{
      const row=this.get(key);
      if(row?.state!=='creating'||row.requestId!==requestId||typeof threadId!=='string'||!threadId)throw new Error('Unexpected conversation creation result');
      this.db.prepare("UPDATE bindings SET state='bound',thread_id=?,updated_at=? WHERE client_key=?").run(threadId,new Date().toISOString(),key);
      this.log(key,'bound',row.generation,threadId,requestId);return this.get(key);
    });
  }
  reset(key,requestId) {
    this.ensureClient(key);
    return this.transaction(()=>{
      const row=this.get(key);
      this.log(key,'explicit-new-conversation',row.generation+1,row.threadId,requestId);
      this.db.prepare("UPDATE bindings SET generation=generation+1,state='unbound',thread_id=NULL,request_id=?,updated_at=? WHERE client_key=?")
        .run(requestId,new Date().toISOString(),key);
      if(requestId)this.activity.record(requestId,'已切换 Codex 会话');
      return this.get(key);
    });
  }
  callResult(requestId){
    const row=this.db.prepare('SELECT * FROM calls WHERE request_id=?').get(requestId);
    if(!row)return null;
    if(row.result_json)return JSON.parse(row.result_json);
    const request=JSON.parse(row.request_json);
    return {ok:false,id:requestId,threadId:this.get(request.clientKey)?.threadId??null,
      error:'The previous invocation was interrupted with an uncertain outcome; it was not sent again'};
  }
  beginCall(request){this.db.prepare("INSERT INTO calls VALUES (?,'started',?,NULL)").run(request.id,JSON.stringify(request));}
  completeCall(requestId,result){
    this.transaction(()=>{
      this.db.prepare("UPDATE calls SET state='completed',result_json=? WHERE request_id=?").run(JSON.stringify(result),requestId);
      this.activity.finish(requestId,result.ok,result.completedAt);
    });
  }
  recoverCalls(){return this.db.prepare('SELECT request_id FROM calls').all().map(row=>[row.request_id,this.callResult(row.request_id)]);}
  explicitReset(request){
    this.ensureClient(request.clientKey);
    return this.transaction(()=>{
      const existing=this.callResult(request.id);if(existing)return existing;
      const row=this.get(request.clientKey);
      this.log(request.clientKey,'explicit-new-conversation',row.generation+1,row.threadId,request.id);
      this.db.prepare("UPDATE bindings SET generation=generation+1,state='unbound',thread_id=NULL,request_id=?,updated_at=? WHERE client_key=?")
        .run(request.id,new Date().toISOString(),request.clientKey);
      const result={ok:true,id:request.id,text:'',threadId:null,generation:row.generation+1,state:'unbound'};
      this.db.prepare("INSERT INTO calls VALUES (?,'completed',?,?)").run(request.id,JSON.stringify(request),JSON.stringify(result));
      this.activity.record(request.id,'已切换 Codex 会话');
      return result;
    });
  }
  close(){this.db.close();}
}
