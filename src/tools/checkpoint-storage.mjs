import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';

const checkpointId=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const samePath=(a,b)=>process.platform==='win32'?a.toLowerCase()===b.toLowerCase():a===b;
function inside(parent,child){
 const relative=path.relative(parent,child);
 return relative!==''&&!relative.startsWith('..'+path.sep)&&relative!=='..'&&!path.isAbsolute(relative);
}
export function hashFile(file){
 const fd=fs.openSync(file,'r'),buffer=Buffer.allocUnsafe(2*1024*1024),hash=createHash('sha256');
 try{let read;while((read=fs.readSync(fd,buffer,0,buffer.length,null))>0)hash.update(buffer.subarray(0,read));}
 finally{fs.closeSync(fd);}
 return hash.digest('hex');
}

// Only the current sealed pair is recovery state. Never infer it from timestamps.
export class CheckpointStorage {
 constructor(root){
  this.root=path.resolve(root);
  this.directory=path.join(this.root,'state/runtime/checkpoints');
  this.pointerFile=path.join(this.root,'state/runtime/current-image.json');
 }
 verify(){
  const raw=fs.readFileSync(this.pointerFile,'utf8'),pointer=JSON.parse(raw);
  if(!checkpointId.test(pointer.id))throw Error('Invalid committed checkpoint identity');
  const directory=path.join(this.directory,pointer.id);
  const image=path.resolve(this.root,pointer.image);
  if(!samePath(image,path.join(directory,'resume.image')))throw Error('Committed checkpoint path is invalid');
  for(const dir of [this.directory,directory]){
   const stat=fs.lstatSync(dir);
   if(!stat.isDirectory()||stat.isSymbolicLink()||!samePath(fs.realpathSync(dir),path.resolve(dir)))
    throw Error('Checkpoint directory must not redirect outside its intended location');
  }
  const changes=image.replace(/\.image$/,'.changes');
  for(const file of [image,changes]){
   const stat=fs.lstatSync(file);
   if(!stat.isFile()||stat.isSymbolicLink())throw Error('Committed checkpoint pair is missing or redirected');
  }
  if(hashFile(image)!==pointer.sha256)throw Error('Committed execution checkpoint is damaged; recovery required');
  if(pointer.changesSha256&&hashFile(changes)!==pointer.changesSha256)
   throw Error('Committed checkpoint changes are damaged; recovery required');
  return {raw,pointer,directory,image,changes};
 }
 plan({protectedImages=[]}={}){
  const selected=this.verify(),kept=[],remove=[],skipped=[];
  for(const item of fs.readdirSync(this.directory,{withFileTypes:true})){
   const directory=path.resolve(this.directory,item.name);
   if(!item.isDirectory()||!checkpointId.test(item.name)||fs.lstatSync(directory).isSymbolicLink()){
    skipped.push(directory);continue;
   }
   if(!inside(this.directory,directory)||!samePath(fs.realpathSync(directory),directory))
    throw Error('Unsafe checkpoint cleanup target');
   if(samePath(directory,selected.directory)||protectedImages.some(file=>inside(directory,path.resolve(file))))
    kept.push(directory);
   else remove.push(directory);
  }
  return {...selected,kept,remove,skipped};
 }
 prune(options={}){
  const plan=this.plan(options),removed=[],errors=[];
  for(const target of plan.remove){
   // Recheck the recovery pointer before each delete; a changed selection aborts cleanup.
   if(fs.readFileSync(this.pointerFile,'utf8')!==plan.raw)throw Error('Checkpoint selection changed during cleanup');
   if(!inside(this.directory,target)||!samePath(fs.realpathSync(target),target))throw Error('Unsafe checkpoint cleanup target');
   try{fs.rmSync(target,{recursive:true,force:true});removed.push(target);}
   catch(error){errors.push({path:target,error:error.message});}
  }
  return {retained:plan.pointer.id,removed,kept:plan.kept,skipped:plan.skipped,errors};
 }
}
