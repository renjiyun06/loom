import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {atomicJSON} from './atomic-files.mjs';

const requestName=/^[a-f0-9-]{36}\.json$/i;
const controlTimeout=10000;
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));

// Management runs from the bridge heartbeat, independently of a waiting model turn.
export class SessionControl {
  constructor({directory,registry,getActive}) {
    this.directory=directory;
    this.registry=registry;
    this.getActive=getActive;
    this.instance=randomUUID();
    this.inbox=path.join(directory,'session-requests');
    this.outbox=path.join(directory,'session-responses');
    for(const dir of [this.inbox,this.outbox])fs.mkdirSync(dir,{recursive:true});
  }
  poll() {
    for(const name of fs.readdirSync(this.inbox).filter(name=>requestName.test(name))) {
      const file=path.join(this.inbox,name);
      const id=path.basename(name,'.json');
      let response;
      try {
        const request=JSON.parse(fs.readFileSync(file,'utf8'));
        if(request.instance!==this.instance)throw new Error('Loom restarted before handling this command');
        response={ok:true,value:this.handle(request,id)};
      } catch(error) {
        response={ok:false,error:error.message};
      }
      atomicJSON(path.join(this.outbox,name),response);
      fs.unlinkSync(file);
    }
  }
  pendingCalls() {
    const active=this.getActive();
    const pending=new Map();
    for(const name of fs.readdirSync(path.join(this.directory,'codex-requests')).filter(name=>requestName.test(name))) {
      const id=path.basename(name,'.json');
      if(id===active?.requestId||fs.existsSync(path.join(this.directory,'codex-responses',name))||
        fs.existsSync(path.join(this.directory,'codex-cancel',name)))continue;
      let request;
      try {request=JSON.parse(fs.readFileSync(path.join(this.directory,'codex-requests',name),'utf8'));}
      catch {continue;}
      if(request?.id!==id||request.action!=='ask'||typeof request.clientKey!=='string')continue;
      if(!pending.has(request.clientKey))pending.set(request.clientKey,[]);
      pending.get(request.clientKey).push(id);
    }
    return {active,pending};
  }
  runningState(session,{active,pending}) {
    const current=active?.clientKey===session.clientKey?active:null;
    const queued=pending.get(session.clientKey)??[];
    const cancelling=current&&fs.existsSync(path.join(this.directory,'codex-cancel',current.requestId+'.json'));
    return {...session,
      runState:current?(cancelling?'stopping':'running'):(queued.length?'queued':'idle'),
      call:current?{requestId:current.requestId,threadId:current.threadId,turnId:current.turnId}:null,
      queued};
  }
  handle({action,sessionId},id) {
    const snapshot=this.pendingCalls();
    if(action==='list')return this.registry.listLoomSessions().map(session=>this.runningState(session,snapshot));
    if(action==='register')return this.runningState(this.registry.registerLoomSession(sessionId),snapshot);
    const existing=this.registry.loomSession(sessionId);
    if(!existing)throw new Error('Loom session does not exist: '+sessionId);
    const session=this.runningState(existing,snapshot);
    if(action==='show')return session;
    if(action==='rotate') {
      if(session.runState!=='idle')throw new Error('Finish or stop the pending calls before switching the Codex session');
      this.registry.explicitReset({id,action:'newConversation',clientKey:session.clientKey});
      return this.runningState(this.registry.loomSession(sessionId),snapshot);
    }
    if(action==='stop') {
      const ids=[...(session.call?[session.call.requestId]:[]),...session.queued];
      for(const requestId of ids)atomicJSON(path.join(this.directory,'codex-cancel',requestId+'.json'),{});
      return {id:sessionId,cancelledRequests:ids};
    }
    throw new Error('Unknown Loom session command');
  }
}

export async function sessionCommand(directory,action,sessionId) {
  const status=JSON.parse(fs.readFileSync(path.join(directory,'bridge-ready.json'),'utf8'));
  if(status.status!=='ready'||!status.sessionControl)throw new Error('Loom session management is not ready');
  const name=randomUUID()+'.json';
  const receipt=path.join(directory,'session-responses',name);
  atomicJSON(path.join(directory,'session-requests',name),{instance:status.sessionControl,action,sessionId});
  const deadline=Date.now()+controlTimeout;
  while(!fs.existsSync(receipt)) {
    if(Date.now()>deadline)throw new Error('Loom session command timed out');
    await sleep(40);
  }
  const response=JSON.parse(fs.readFileSync(receipt,'utf8'));
  fs.unlinkSync(receipt);
  if(!response.ok)throw new Error(response.error);
  return response.value;
}
