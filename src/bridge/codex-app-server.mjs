import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import {spawn} from 'node:child_process';
import {EventEmitter} from 'node:events';
import {evaluate} from './runtime-client.mjs';

export class CodexAppServer extends EventEmitter {
  constructor({codexPath, cwd, runtimeDirectory, logsDirectory=runtimeDirectory, env=process.env,sessionRegistry,saveObjectResult}) {
    super();
    this.cwd=cwd;
    this.runtimeDirectory=runtimeDirectory;
    this.sessionRegistry=sessionRegistry;
    this.saveObjectResult=saveObjectResult;
    this.pending=new Map();
    this.loadedThreads=new Set();
    this.threadModels=new Map();
    this.nextId=0;
    this.active=null;
    this.stderr=fs.createWriteStream(path.join(logsDirectory,'codex.stderr.log'),{flags:'a'});
    this.child=spawn(codexPath,['app-server','--stdio'],{
      cwd, env, windowsHide:true, stdio:['pipe','pipe','pipe'],
    });
    this.child.stderr.pipe(this.stderr);
    this.child.stdin.on('error',e=>this.fail(e));
    this.child.on('error',e=>this.fail(e));
    this.child.on('exit',(code,signal)=>this.fail(new Error(`Codex App Server exited: ${code ?? signal}`)));
    readline.createInterface({input:this.child.stdout}).on('line',line=>{
      if(!line.trim()) return;
      try { this.receive(JSON.parse(line)); }
      catch(e) { this.fail(new Error(`Invalid App Server message: ${e.message}`)); }
    });
  }
  send(message) {
    if(this.dead) throw this.dead;
    this.child.stdin.write(JSON.stringify(message)+'\n');
  }
  request(method,params,timeout=30000,onResult=null) {
    return new Promise((resolve,reject)=>{
      const id=++this.nextId;
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error(`App Server timeout: ${method}`));},timeout);
      this.pending.set(id,{resolve,reject,timer,onResult});
      try { this.send({id,method,params}); }
      catch(e) {clearTimeout(timer);this.pending.delete(id);reject(e);}
    });
  }
  receive(message) {
    const turnId = message.params?.turnId ?? message.params?.turn?.id;
    if (this.active && message.params?.threadId === this.active.threadId &&
        (!this.active.turnId || !turnId || turnId === this.active.turnId)) {
      this.sessionRegistry.activity.accept(this.active.requestId,message,new Date().toISOString());
    }
    if(message.method && Object.hasOwn(message,'id')) {
      void this.handleServerRequest(message).catch(error=>{
        try {this.send({id:message.id,error:{code:-32603,message:error.message}});} catch {}
      });
    } else if(Object.hasOwn(message,'id')) {
      const pending=this.pending.get(message.id);
      if(!pending) return;
      clearTimeout(pending.timer);this.pending.delete(message.id);
      if(message.error) pending.reject(new Error(`${message.error.code}: ${message.error.message}`));
      else {
        try {pending.onResult?.(message.result);pending.resolve(message.result);}
        catch(error){pending.reject(error);}
      }
    } else if(message.method) {
      this.emit('notification',message);
    }
  }
  async handleServerRequest(message) {
    if(message.method==='item/tool/call') {
      const params=message.params;
      const active=this.active;
      if(!active || params.tool!=='runtime_eval' || params.threadId!==active.threadId ||
         (params.turnId && active.turnId && params.turnId!==active.turnId)) {
        this.send({id:message.id,result:{success:false,contentItems:[{type:'inputText',text:'Tool is not available for this runtime invocation.'}]}});
        return;
      }
      let result;
      try {
        const args=typeof params.arguments==='string'?JSON.parse(params.arguments):params.arguments;
        if(typeof args?.code!=='string') throw new Error('Expected Smalltalk source in code');
        result=await this.evaluateTool(args.code,active);
      } catch(error) { result={ok:false,error:error.message}; }
      this.send({id:message.id,result:{success:result.ok,contentItems:[{type:'inputText',text:JSON.stringify(result)}]}});
      return;
    }
    // Approval/UI requests are never silently accepted by this headless transport.
    this.send({id:message.id,error:{code:-32601,message:`Unsupported interactive request: ${message.method}`}});
  }
  async evaluateTool(code,active) {
    const run=source=>evaluate(source,`codex-tool-${this.nextId++}`,30000,this.runtimeDirectory);
    if(!active.objectInvocation)return run(code);
    // The request ID has been validated by ingress. Resolve the session from the active client binding.
    const sessionId=this.sessionRegistry.loomSessionIdForClient(active.clientKey);
    const sessionLiteral=sessionId===null?'nil':"'"+sessionId.replaceAll("'","''")+"'";
    const evaluated=await run(`(LMInvocation pendingAt: '${active.requestId}')
      evaluate: [ :loomCaller :loomMessage :loomSessionId :loomReturn |
      ${code}
      ] sessionId: ${sessionLiteral}`.replace(/\r?\n/g,'\r'));
    if(!evaluated.ok)return evaluated;
    if(!Array.isArray(evaluated.value)||typeof evaluated.value[0]!=='boolean') {
      throw new Error('Invalid result from Loom object invocation callback');
    }
    const [hasResult,value]=evaluated.value;
    if(hasResult) {
      // Save the actual GT object before the tool acknowledges it and before a successful
      // turn receipt can be replayed after restart.
      active.objectSave ??= this.saveObjectResult();
      await active.objectSave;
    }
    return {ok:true,value};
  }
  fail(error) {
    if(this.dead) return;
    this.dead=error;
    for(const pending of this.pending.values()) {clearTimeout(pending.timer);pending.reject(error);}
    this.pending.clear();
    this.emit('failure',error);
  }
  async initialize() {
    return this.request('initialize',{
      clientInfo:{name:'loom_bridge',title:'Loom Bridge',version:'0.1.0'},
      capabilities:{experimentalApi:true,requestAttestation:false},
    }).then(result=>{this.send({method:'initialized'});return result;});
  }
  async call(request,overrides={}) {
    if(this.active) throw new Error('The bridge processes one turn at a time');
    const active=this.active={requestId:request.id,clientKey:request.clientKey,threadId:null,turnId:null,
      objectInvocation:request.objectInvocation===true};
    const startedAt=new Date().toISOString();
    const params={cwd:this.cwd,approvalPolicy:'never',sandbox:'read-only'};
    try {
      const binding=this.sessionRegistry.ensureClient(request.clientKey);
      active.threadId=binding.threadId;
      if(binding.state==='creating')throw new Error('Previous conversation creation has an uncertain outcome; refusing to create another conversation');
      let thread;
      if(active.threadId) {
        if(!this.loadedThreads.has(active.threadId)) {
          const resumed=await this.request('thread/resume',{...params,threadId:active.threadId,excludeTurns:true});
          thread=resumed.thread;
          if(thread.id!==active.threadId)throw new Error('Codex resumed a different conversation; refusing to continue');
          this.threadModels.set(active.threadId,resumed.model);
          this.loadedThreads.add(active.threadId);
        }
      } else {
        this.sessionRegistry.beginCreate(request.clientKey,request.id);
        const created=await this.request('thread/start',{
          ...params,
          dynamicTools:[{
            type:'function',name:'runtime_eval',
            description:'Evaluate Smalltalk in the live GT runtime that issued this call. Object calls bind loomCaller (Context), loomMessage (Message), loomSessionId (Loom session ID), and loomReturn (a one-argument block for returning a live object). Tool output must be JSON-serializable. See AGENTS.md. Do not synchronously invoke LoomCodex from this tool.',
            inputSchema:{type:'object',properties:{code:{type:'string'}},required:['code'],additionalProperties:false},
          }],
        },30000,result=>this.sessionRegistry.bindCreated(request.clientKey,request.id,result.thread.id));
        thread=created.thread;
        active.threadId=thread.id;
        active.model=created.model;
        this.threadModels.set(thread.id,created.model);
        this.loadedThreads.add(thread.id);
        await this.request('thread/name/set',{threadId:thread.id,name:'织境 Loom'});
      }
      const messages=new Map();
      let completed,rejectOnFailure;
      const completion=new Promise((resolve,reject)=>{
        completed=notification=>{
          if(notification.params?.threadId!==active.threadId) return;
          if(notification.method==='item/completed') {
            const item=notification.params.item;
            if(item?.type==='agentMessage') messages.set(item.id,item);
          }
          if(notification.method==='turn/completed') {
            const turn=notification.params.turn;
            if(active.turnId && turn.id!==active.turnId) return;
            resolve(turn);
          }
        };
        rejectOnFailure=reject;
        this.on('notification',completed);
        this.once('failure',rejectOnFailure);
        // Model work has no duration limit. Explicit cancellation and transport failure still settle this turn.
      });
      // Settle unexpected early completion failures without an unhandled rejection.
      completion.catch(()=>{});
      try {
        const turnParams={
          threadId:active.threadId,input:[{type:'text',text:request.prompt,text_elements:[]}],
          ...overrides,
        };
        const turnResponse=await this.request('turn/start',turnParams);
        active.turnId=turnResponse.turn.id;
        const turn=await completion;
        for(const item of turn.items ?? []) if(item.type==='agentMessage') messages.set(item.id,item);
        if(turn.status!=='completed') throw new Error(turn.error?.message ?? `Codex turn ${turn.status}`);
        const all=[...messages.values()];
        const finals=all.filter(item=>item.phase==='final_answer');
        const text=(finals.length?finals:all).map(item=>item.text).filter(Boolean).join('\n');
        if(active.objectInvocation) {
          if(!active.objectSave)throw new Error('Codex completed without returning a GT object');
          await active.objectSave;
        } else if(!text) {
          throw new Error('Completed Codex turn did not contain an assistant answer');
        }
        return {ok:true,id:request.id,text,threadId:active.threadId,turnId:turn.id,
          model:overrides.model ?? this.threadModels.get(active.threadId) ?? null,startedAt,completedAt:new Date().toISOString()};
      } catch(error) {
        if(active.turnId && !this.dead) {
          await this.request('turn/interrupt',{threadId:active.threadId,turnId:active.turnId},5000).catch(()=>{});
        }
        throw error;
      } finally {
        this.off('notification',completed);this.off('failure',rejectOnFailure);
      }
    } catch(error) {
      return {ok:false,id:request.id,error:error.message,threadId:active.threadId,turnId:active.turnId,
        startedAt,completedAt:new Date().toISOString()};
    } finally { this.active=null; }
  }
  async interrupt() {
    if(this.active?.turnId) await this.request('turn/interrupt',{
      threadId:this.active.threadId,turnId:this.active.turnId},5000);
  }
  close() {this.child.stdin.end();if(this.child.exitCode===null)this.child.kill();this.stderr.end();}
}
