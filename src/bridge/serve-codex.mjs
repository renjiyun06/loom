import fs from 'node:fs';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {CodexAppServer} from './codex-app-server.mjs';
import {evaluate,archivePendingCommands} from './runtime-client.mjs';
import {root,paths,childEnvironment} from './paths.mjs';
import {SessionRegistry} from './session-registry.mjs';
import {SessionControl} from './session-control.mjs';
import {ActivityFeed} from './activity-feed.mjs';
import {migrateActivities} from './activity-store.mjs';
import {CodexSettings} from './codex-settings.mjs';
import {Checkpoints} from './checkpoints.mjs';
import {NativeLifecycle} from './native-lifecycle.mjs';
import {atomicJSON} from './atomic-files.mjs';
import {VoiceService} from '../audio/voice-service.mjs';
import {openEnvironment} from './open-environment.mjs';

const live=paths.ipc;
const statusFile=path.join(live,'bridge-ready.json');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
for(const directory of [live,paths.workspace,paths.logs,paths.codexHome,paths.temporary,path.dirname(paths.image),paths.backups,
  ...['codex-requests','codex-responses','codex-cancel','checkpoint-requests','checkpoint-results','checkpoint-saved','checkpoint-joined','native-actions','native-results'].map(name=>path.join(live,name))]) {
  fs.mkdirSync(directory,{recursive:true});
}
const settings=new CodexSettings(path.join(root,'config','codex.json'),path.join(paths.codexHome,'models_cache.json'));
const status={status:'starting',pid:process.pid,startedAt:new Date().toISOString(),root,
  runtimeDirectory:live,image:paths.image,codexHome:paths.codexHome,cwd:paths.workspace,
  supervisorPid:Number(process.env.LOOM_JOB_SUPERVISOR_PID)||null};
const gui=JSON.parse(fs.readFileSync(path.join(root,'config/runtime.json'),'utf8').replace(/^\uFEFF/,'' )).gui===true;
status.gui=gui;
let vm,server,registry,checkpoints,checkpointWatcher,nativeLifecycle,nativeWatcher,nativeShutdown,voice,voiceWatcher,shutdownRequested=false,expectedVmExit=false,watcher,activeRequest=null,fatalError=null,finished=false;
function writeStatus(phase,extra={}){
  if(phase==='ready')fs.writeFileSync(path.join(live,'bridge-heartbeat.txt'),new Date().toISOString());
  atomicJSON(statusFile,{...status,status:phase,...extra});
}
function fail(error){
  if(finished)return;
  fatalError=error;shutdownRequested=true;
  clearInterval(watcher);
  clearInterval(checkpointWatcher);
  clearInterval(nativeWatcher);
  clearInterval(voiceWatcher);
  writeStatus('failed',{error:error.message,stoppedAt:new Date().toISOString()});
  emergencyCleanup();
  // Do not wait for an outstanding model turn after its environment has failed.
  process.exit(1);
}
function emergencyCleanup(){
  if(finished)return;
  if(vm?.exitCode===null)vm.kill();
  server?.close();
  registry?.close();registry=null;
}
process.on('exit',emergencyCleanup);
process.on('SIGINT',()=>{shutdownRequested=true;});process.on('SIGTERM',()=>{shutdownRequested=true;});
try {
  if(!status.supervisorPid)throw new Error('Start this environment through start.ps1 so all processes are job-supervised');
  writeStatus('starting');
  registry=new SessionRegistry(path.join(root,'state/bridge'));
  migrateActivities(registry, paths);
  const activityFeed=new ActivityFeed(live,registry.activity);
  for(const call of registry.db.prepare("SELECT request_id FROM calls WHERE state='started'").all()) {
    registry.activity.finish(call.request_id,false);
  }
  checkpoints=new Checkpoints();status.image=checkpoints.image;
  archivePendingCommands();
  for(const [id,result] of registry.recoverCalls())atomicJSON(path.join(live,'codex-responses',id+'.json'),result);
  for(const name of fs.readdirSync(path.join(live,'codex-requests')).filter(n=>n.endsWith('.json'))) {
    const response=path.join(live,'codex-responses',name);
    const recovered=registry.callResult(path.basename(name,'.json'));
    if(recovered)atomicJSON(response,recovered);
  }
  if(!fs.existsSync(checkpoints.image)) {
    fs.copyFileSync(paths.seedImage,paths.image);
    fs.copyFileSync(paths.seedImage.replace(/\.image$/,'.changes'),paths.image.replace(/\.image$/,'.changes'));
    for(const name of fs.readdirSync(path.dirname(paths.seedImage)).filter(n=>n.endsWith('.sources'))) {
      fs.copyFileSync(path.join(path.dirname(paths.seedImage),name),path.join(path.dirname(paths.image),name));
    }
  }
  const readyFile=path.join(live,'ready.json');if(fs.existsSync(readyFile))fs.unlinkSync(readyFile);
  const out=fs.openSync(path.join(paths.logs,'runtime.stdout.log'),'a');
  const err=fs.openSync(path.join(paths.logs,'runtime.stderr.log'),'a');
  // The GUI executable only accepts --image; the CLI hosts custom startup commands.
  const engineExecutable=paths.engineExecutable;
  const workingImage=checkpoints.prepareWorkingImage();status.workingImage=workingImage;
  vm=spawn(engineExecutable,[...(gui?['--interactive']:[]),workingImage,'st',path.join(root,'src/runtime/bootstrap.st')],
    {cwd:root,env:childEnvironment,windowsHide:true,stdio:['ignore',out,err]});
  status.enginePid=vm.pid;writeStatus('starting');
  fs.closeSync(out);fs.closeSync(err);
  vm.on('error',fail);
  vm.on('exit',code=>{if(!expectedVmExit)fail(new Error(`Runtime exited unexpectedly: ${code}`));});
  const deadline=Date.now()+20000;
  while(!fs.existsSync(readyFile)) {if(Date.now()>deadline||fatalError)throw fatalError??new Error('Runtime startup timeout');await sleep(30);}
  const execution=await evaluate(fs.readFileSync(path.join(root,'src/runtime/execution.st'),'utf8'),'install-execution');
  if(!execution.ok)throw new Error(JSON.stringify(execution));
  const mode=await evaluate(`Smalltalk globals at: #LoomGuiEnabled put: ${gui}. true`,'runtime-mode');
  if(!mode.ok)throw new Error(JSON.stringify(mode));
  const renderer=await evaluate(fs.readFileSync(path.join(root,'src/runtime/desktop-compat.st'),'utf8').replace(/\r?\n/g,'\r'),'install-renderer');
  if(!renderer.ok)throw new Error(JSON.stringify(renderer));
  const ime=await evaluate(fs.readFileSync(path.join(root,'src/runtime/windows-ime.st'),'utf8').replace(/\r?\n/g,'\r'),'install-ime');
  if(!ime.ok)throw new Error(JSON.stringify(ime));
  const lifecycle=await evaluate(fs.readFileSync(path.join(root,'src/runtime/native-lifecycle.st'),'utf8').replace(/\r?\n/g,'\r'),'install-native-lifecycle');
  if(!lifecycle.ok)throw new Error(JSON.stringify(lifecycle));
  nativeLifecycle=new NativeLifecycle({session:JSON.parse(fs.readFileSync(readyFile,'utf8')).session,checkpoints,beginShutdown:request=>{
    nativeShutdown=request;shutdownRequested=true;writeStatus('stopping');
    clearInterval(checkpointWatcher);clearInterval(nativeWatcher);
  }});
  const installed=await evaluate('Smalltalk globals includesKey: #LMCodexClient','check-client');
  if(!installed.ok)throw new Error(JSON.stringify(installed));
  const version=installed.value?await evaluate('(LMCodexClient class canUnderstand: #bridgeVersion) ifTrue: [ LMCodexClient bridgeVersion ] ifFalse: [ 0 ]','client-version'):{value:0};
  if(version.value<11) {
    const result=await evaluate(fs.readFileSync(path.join(root,'src/runtime/codex-client.st'),'utf8'),'install-codex-client');
    if(!result.ok)throw new Error(JSON.stringify(result));
  } else if(version.value<12) {
    const result=await evaluate(fs.readFileSync(path.join(root,'src/runtime/object-invocation.st'),'utf8'),'upgrade-object-invocation');
    if(!result.ok)throw new Error(JSON.stringify(result));
  }
  const conversationInstalled=await evaluate('Smalltalk globals includesKey: #LoomConversation','check-conversation');
  if(!conversationInstalled.ok)throw new Error(JSON.stringify(conversationInstalled));
  if(!conversationInstalled.value){
    const conversation=await evaluate(fs.readFileSync(path.join(root,'src/runtime/conversation.st'),'utf8').replace(/\r?\n/g,'\r'),'install-conversation');
    if(!conversation.ok)throw new Error(JSON.stringify(conversation));
  }
  const mainSession=await evaluate(fs.readFileSync(path.join(root,'src/runtime/upgrade-main-session.st'),'utf8'),'upgrade-main-session');
  if(!mainSession.ok)throw new Error(JSON.stringify(mainSession));
  const voiceVersion=await evaluate('(Smalltalk globals includesKey: #LMVoice) ifTrue: [ (Smalltalk globals at: #LMVoice) featureVersion ] ifFalse: [ 0 ]','check-voice');
  if(!voiceVersion.ok)throw new Error(JSON.stringify(voiceVersion));
  if(voiceVersion.value<2){
    const installedVoice=await evaluate(fs.readFileSync(path.join(root,'src/runtime/voice.st'),'utf8').replace(/\r?\n/g,'\r'),'install-voice');
    if(!installedVoice.ok)throw new Error(JSON.stringify(installedVoice));
  }
  voice=new VoiceService(root,{notify:async()=>{
    if(shutdownRequested)return;
    const notified=await evaluate('LoomConversation start. true','voice-ready-'+Date.now());
    if(!notified.ok)throw new Error('Cannot notify Loom of transcription completion');
  }});
  const legacy=await evaluate('LoomCodex threadId','legacy-session-binding');
  if(!legacy.ok)throw new Error(JSON.stringify(legacy));
  const binding=registry.initializeDefault(legacy.value);
  const literal=binding.threadId?"'"+binding.threadId.replaceAll("'","''")+"'":'nil';
  const restored=await evaluate(`LoomCodex clientKey: 'default'. LoomCodex synchronizeThreadId: ${literal}. 'restored'`,'restore-durable-binding');
  if(!restored.ok)throw new Error(JSON.stringify(restored));
  server=new CodexAppServer({codexPath:paths.codexExecutable,cwd:paths.workspace,runtimeDirectory:live,
    logsDirectory:paths.logs,env:childEnvironment,sessionRegistry:registry,
    saveObjectResult:()=>checkpoints.saveAndWait()});
  const sessionControl=new SessionControl({directory:live,registry,getActive:()=>server.active});
  status.sessionControl=sessionControl.instance;
  status.codexPid=server.child.pid;writeStatus('starting');
  server.on('failure',error=>{if(!shutdownRequested)fail(error);});
  const initialized=await server.initialize();
  Object.assign(status,{enginePid:vm.pid,codexPid:server.child.pid,transport:'Codex App Server / stdio',appServer:initialized.userAgent??null});
  await checkpoints.restore();
  const nativeRestored=await evaluate('LMExecution restoreNativeAction','restore-native-caller');
  if(!nativeRestored.ok)throw new Error(JSON.stringify(nativeRestored));
  checkpointWatcher=setInterval(()=>{void checkpoints.poll().then(()=>{
    if(status.image!==checkpoints.image){status.image=checkpoints.image;writeStatus(shutdownRequested?'stopping':'ready');}
  }).catch(fail);},50);
  const stopFile=path.join(live,'stop.json');
  watcher=setInterval(()=>{
    fs.writeFileSync(path.join(live,'bridge-heartbeat.txt'),new Date().toISOString());
    try { activityFeed.poll(); } catch(error) { console.error(`Activity view: ${error.message}`); }
    try { sessionControl.poll(); } catch(error) { console.error(`Loom sessions: ${error.message}`); }
    const heartbeat=path.join(live,'runtime-heartbeat.txt');
    if(!checkpoints.busy&&(!fs.existsSync(heartbeat)||Date.now()-fs.statSync(heartbeat).mtimeMs>10000)) {
      fail(new Error('Runtime heartbeat stopped; terminating the complete execution environment'));return;
    }
    if(fs.existsSync(stopFile))shutdownRequested=true;
    const cancelled=activeRequest && fs.existsSync(path.join(live,'codex-cancel',`${activeRequest}.json`));
    if((shutdownRequested||cancelled)&&server.active?.turnId&&!server.active.interruptionSent) {
      server.active.interruptionSent=true;void server.interrupt().catch(()=>{});
    }
  },100);
  nativeWatcher=setInterval(()=>{void nativeLifecycle.poll().catch(fail);},100);
  const uiVersion=await evaluate('(Smalltalk globals at: #LMConversationUI ifAbsent: [ nil ]) ifNil: [ 0 ] ifNotNil: [ :ui | ui featureVersion ]','check-ui');
  if(!uiVersion.ok)throw new Error(JSON.stringify(uiVersion));
  if(uiVersion.value<21){
    const ui=await evaluate(fs.readFileSync(path.join(root,'src/runtime/conversation-ui.st'),'utf8').replace(/\r?\n/g,'\r'),'install-ui');
    if(!ui.ok)throw new Error(JSON.stringify(ui));
  }
  if(gui){
    const sessionUI=await evaluate(`(Smalltalk globals includesKey: #LMSessionManagerUI) ifFalse: [
      Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'loom-session-ui.st') contents ].
      true`,'install-session-manager-tab');
    if(!sessionUI.ok)throw new Error(JSON.stringify(sessionUI));
    const activityUI=await evaluate(`(Smalltalk globals includesKey: #LMActivityOverviewUI) ifFalse: [
      Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'loom-activity-ui.st') contents ].
      true`,'install-activity-overview-tab');
    if(!activityUI.ok)throw new Error(JSON.stringify(activityUI));
    await openEnvironment({restoreConversation:true});
  }
  atomicJSON(path.join(live,'codex-options.json'),settings.options());
  status.objectInvocation=true;
  writeStatus('ready');
  const dialogue=await evaluate("LoomConversation start. 'conversation ready'",'start-conversation');
  if(!dialogue.ok)throw new Error(JSON.stringify(dialogue));
  voiceWatcher=setInterval(()=>{void voice.poll().catch(fail);},200);
  console.log(JSON.stringify({...status,status:'ready'}));
  while(!shutdownRequested) {
    for(const name of fs.readdirSync(path.join(live,'codex-requests')).filter(n=>n.endsWith('.json')).sort()) {
      if(shutdownRequested)break;
      const id=path.basename(name,'.json');if(!/^[a-f0-9-]{36}$/i.test(id))continue;
      const responseFile=path.join(live,'codex-responses',name);if(fs.existsSync(responseFile))continue;
      let request;
      try {request=JSON.parse(fs.readFileSync(path.join(live,'codex-requests',name),'utf8'));}
      catch{atomicJSON(responseFile,{ok:false,id,error:'Invalid request JSON'});continue;}
      if(!request||request.id!==id||!['ask','newConversation','status','configure'].includes(request.action)||
        typeof request.clientKey!=='string'||!/^[a-zA-Z0-9._-]{1,128}$/.test(request.clientKey)||
        typeof request.prompt!=='string'||(request.action==='ask'&&!request.prompt.trim())||
        (request.objectInvocation!==undefined && !(request.objectInvocation===true && request.action==='ask'))||
        !(request.threadId===null||typeof request.threadId==='string')) {
        atomicJSON(responseFile,{ok:false,id,error:'Invalid Codex request'});continue;
      }
      if(request.action==='configure') {
        try {
          const options=settings.save(JSON.parse(request.prompt));
          atomicJSON(path.join(live,'codex-options.json'),options);
          atomicJSON(responseFile,{ok:true,id,text:''});
        } catch(error) {
          atomicJSON(responseFile,{ok:false,id,error:error.message});
        }
        continue;
      }
      if(request.action!=='ask') {
        const current=request.action==='newConversation'?registry.explicitReset(request):registry.ensureClient(request.clientKey);
        atomicJSON(responseFile,request.action==='newConversation'?current:{ok:true,id,text:'',threadId:current.threadId,generation:current.generation,state:current.state});
        continue;
      }
      if(fs.existsSync(path.join(live,'codex-cancel',name))) {
        atomicJSON(responseFile,{ok:false,id,error:'Request cancelled before execution'});continue;
      }
      activeRequest=id;
      let result=registry.callResult(id);
      if(!result){
        registry.beginCall(request);
        try {
          result=await server.call(request,settings.turnParams());
        } catch(error) {
          result={ok:false,id,error:error.message};
        }
        registry.completeCall(id,result);
      }
      atomicJSON(responseFile,result);activeRequest=null;
      console.log(JSON.stringify({id,ok:result.ok,threadId:result.threadId,turnId:result.turnId}));
    }
    await sleep(50);
  }
  clearInterval(watcher);
  clearInterval(checkpointWatcher);
  clearInterval(nativeWatcher);
  clearInterval(voiceWatcher);
  await voice.close();
  if(fatalError)throw fatalError;
  writeStatus('stopping');
  const shouldSave=nativeShutdown?.save!==false;
  const shutdownCheckpoint=shouldSave?await checkpoints.saveAndWait():null;status.image=checkpoints.image;
  if(nativeShutdown)nativeLifecycle.completeQuit(nativeShutdown,shutdownCheckpoint);
  expectedVmExit=true;
  const snapshot=await evaluate("[ (Delay forMilliseconds: 200) wait. Smalltalk exitSuccess ] fork. 'exit scheduled'",'save-and-stop');
  if(!snapshot.ok)throw new Error(JSON.stringify(snapshot));
  const exitDeadline=Date.now()+20000;
  while(vm.exitCode===null&&Date.now()<exitDeadline)await sleep(50);
  if(vm.exitCode!==0)throw new Error('Runtime did not finish saving its image');
  // The verified committed checkpoint is also the saved-shutdown recovery copy.
  // Do not accumulate another full image/changes pair on every exit.
  const backup=null;
  server.close();
  registry.close();registry=null;
  if(fs.existsSync(stopFile))fs.unlinkSync(stopFile);
  writeStatus('stopped',{saved:shouldSave,backup,stoppedAt:new Date().toISOString()});finished=true;
  process.exit(0);
} catch(error) {
  clearInterval(watcher);console.error(error.stack);
  clearInterval(checkpointWatcher);
  clearInterval(nativeWatcher);
  clearInterval(voiceWatcher);
  if(activeRequest)atomicJSON(path.join(live,'codex-responses',`${activeRequest}.json`),{ok:false,id:activeRequest,error:error.message});
  emergencyCleanup();writeStatus('failed',{error:error.message,stoppedAt:new Date().toISOString()});
  finished=true;process.exitCode=1;
}
