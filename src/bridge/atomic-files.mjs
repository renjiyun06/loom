import fs from 'node:fs';
// Windows readers or indexing software may briefly deny replacement. Keep the old
// committed file intact and retry the atomic rename; never unlink the destination.
const sleeper=new Int32Array(new SharedArrayBuffer(4));
export function replaceFileSync(source,target){
 const deadline=Date.now()+500;
 for(;;){
  try{fs.renameSync(source,target);return;}
  catch(error){
   if(process.platform!=='win32'||!['EPERM','EACCES','EBUSY'].includes(error.code)||Date.now()>=deadline)throw error;
   Atomics.wait(sleeper,0,0,10);
  }
 }
}
export function atomicJSON(file,value) {
 const temp=file+'.tmp';
 fs.writeFileSync(temp,JSON.stringify(value,null,2));
 replaceFileSync(temp,file);
}
