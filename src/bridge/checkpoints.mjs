import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {root,paths} from './paths.mjs';
import {evaluate} from './runtime-client.mjs';
import {replaceFileSync} from './atomic-files.mjs';
import {CheckpointStorage,hashFile} from './checkpoint-storage.mjs';
const pointerFile=path.join(root,'state/runtime/current-image.json');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
function publish(file,value){const temp=file+'.tmp';const fd=fs.openSync(temp,'w');try{fs.writeFileSync(fd,JSON.stringify(value,null,2));fs.fsyncSync(fd);}finally{fs.closeSync(fd);}replaceFileSync(temp,file);}
function sync(file){const fd=fs.openSync(file,'r+');try{fs.fsyncSync(fd);}finally{fs.closeSync(fd);}}
export function selectedImage(){
 if(!fs.existsSync(pointerFile))return paths.image;
 return new CheckpointStorage(root).verify().image;
}
export class Checkpoints {
 constructor(){
  this.image=selectedImage();this.busy=false;this.lastCommitted=null;this.failure=null;
  const pointer=fs.existsSync(pointerFile)?JSON.parse(fs.readFileSync(pointerFile,'utf8')):null;
  for(const name of fs.readdirSync(path.join(paths.ipc,'checkpoint-requests')).filter(n=>n.endsWith('.json'))){
   const result=path.join(paths.ipc,'checkpoint-results',name);if(fs.existsSync(result))continue;
   const id=path.basename(name,'.json');
   publish(result,pointer?.id===id?{ok:true,...pointer}:{ok:false,id,error:'Interrupted before checkpoint commit; request was not replayed'});
  }
 }
 async restore(){
  const result=await evaluate("(Smalltalk globals at: #BridgeExecutionCheckpoint ifAbsent: [ nil ]) ifNotNil: [ :state | (state at: 'gate') signal ]. 'execution released'",'resume-execution');
  if(!result.ok)throw new Error(JSON.stringify(result));
 }
 prepareWorkingImage(){
  // Native runtime's Save command must never overwrite the committed recovery image.
  const directory=path.join(root,'state/runtime/working');fs.mkdirSync(directory,{recursive:true});
  const image=path.join(directory,'main.image');
  for(const extension of ['.image','.changes'])fs.copyFileSync(this.image.replace(/\.image$/,extension),image.replace(/\.image$/,extension));
  for(const name of fs.readdirSync(path.dirname(paths.seedImage)).filter(n=>n.endsWith('.sources'))) {
   const target=path.join(directory,name);
   if(!fs.existsSync(target))fs.copyFileSync(path.join(path.dirname(paths.seedImage),name),target);
  }
  const resources=path.join(directory,'gt-extra');
  if(!fs.existsSync(resources))fs.symlinkSync(path.join(path.dirname(paths.seedImage),'gt-extra'),resources,'junction');
  return image;
 }
 async poll(){
  if(this.busy)return;
  for(const name of fs.readdirSync(path.join(paths.ipc,'checkpoint-requests')).filter(n=>n.endsWith('.json'))){
   const id=path.basename(name,'.json');if(!/^[a-f0-9-]{36}$/i.test(id))continue;
   if(fs.existsSync(path.join(paths.ipc,'checkpoint-results',name)))continue;
   this.busy=true;
   try{await this.create(id);}catch(error){this.failure=error;throw error;}finally{this.busy=false;}
  }
 }
 async create(id){
  const directory=path.join(root,'state/runtime/checkpoints',id);fs.mkdirSync(directory,{recursive:true});
  // The mutable working pair stays at one fixed path; seal just one copy per commit.
  const working=path.join(root,'state/runtime/working');fs.mkdirSync(working,{recursive:true});
  const stem=path.join(working,'main').replaceAll("'","''");
  const workingImage=path.join(working,'main.image').replaceAll("'","''");
  const snapshotCode=`[
    | operation |
    LMExecution nativeStateCritical: [
      BridgeMailboxProcess suspend.
      operation := LMExecution nativeSnapshotDuring: [
        Smalltalk imageFile fullName = '${workingImage}'
         ifTrue: [ Smalltalk snapshot: true andQuit: false ]
         ifFalse: [ Smalltalk saveAs: '${stem}' ] ].
      operation isImageStarting ifFalse: [
        BridgeMailboxProcess resume.
        (BridgeIPC / 'checkpoint-saved' / '${id}.json') writeStreamDo: [ :s | s nextPutAll: '{}' ]
      ] ]
   ]`;
  const started=await evaluate(`(Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ])
    ifTrue: [ BlHost pickHost universe postpone: ${snapshotCode} ]
    ifFalse: [ ${snapshotCode} fork ]. 'snapshot scheduled'`,'execution-checkpoint');
  if(!started.ok)throw new Error(JSON.stringify(started));
  const saved=path.join(paths.ipc,'checkpoint-saved',id+'.json');const deadline=Date.now()+30000;
  while(!fs.existsSync(saved)){if(Date.now()>deadline)throw new Error('Execution checkpoint save timed out');await sleep(30);}
  // The VM keeps its active .changes open for writing on Windows. Publish a sealed pair.
  const image=path.join(directory,'resume.image');
  const changes=path.join(directory,'resume.changes');
  fs.copyFileSync(path.join(working,'main.image'),image);
  fs.copyFileSync(path.join(working,'main.changes'),changes);
  sync(image);sync(changes);
  const pointer={id,image:path.relative(root,image),sha256:hashFile(image),changesSha256:hashFile(changes),committedAt:new Date().toISOString()};
  publish(pointerFile,pointer);this.image=image;this.lastCommitted=id;
  publish(path.join(paths.ipc,'checkpoint-results',id+'.json'),{ok:true,...pointer});
  await this.restore();
  // Retention failure cannot invalidate an already committed, released snapshot.
  try{
   const retained=new CheckpointStorage(root).prune({protectedImages:[path.join(working,'main.image')]});
   publish(path.join(paths.logs,'checkpoint-retention.json'),{checkedAt:new Date().toISOString(),...retained});
  }catch(error){console.error('Checkpoint retention deferred:',error.message);}
 }
 async saveAndWait(){
  while(this.busy)await sleep(30);
  const token=randomUUID();
  const receipt=path.join(paths.ipc,'checkpoint-joined',token+'.json');
  const started=await evaluate(`[ | id | id := LMExecution checkpoint.
   (BridgeIPC / 'checkpoint-joined' / '${token}.json') writeStreamDo: [ :s |
    s nextPutAll: (STONJSON toString: (Dictionary new at: 'id' put: id; yourself)) ]
   ] fork. 'checkpoint requested'`,'joined-checkpoint');
  if(!started.ok)throw new Error(JSON.stringify(started));
  const deadline=Date.now()+35000;
  while(!fs.existsSync(receipt)){await this.poll();if(this.failure)throw this.failure;if(Date.now()>deadline)throw new Error('Joined checkpoint timed out');await sleep(30);}
  return JSON.parse(fs.readFileSync(receipt,'utf8')).id;
 }
}
