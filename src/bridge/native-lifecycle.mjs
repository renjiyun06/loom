import fs from 'node:fs';
import path from 'node:path';
import {paths} from './paths.mjs';
import {evaluate} from './runtime-client.mjs';
import {replaceFileSync} from './atomic-files.mjs';
const literal=value=>"'"+value.replaceAll("'","''")+"'";
function publish(file,value){const temp=file+'.tmp';fs.writeFileSync(temp,JSON.stringify(value));replaceFileSync(temp,file);}
export class NativeLifecycle {
 constructor({session,checkpoints,beginShutdown}){
  this.session=session;this.checkpoints=checkpoints;this.beginShutdown=beginShutdown;this.busy=false;
 }
 async poll(){
  if(this.busy)return;
  for(const name of fs.readdirSync(path.join(paths.ipc,'native-actions')).filter(n=>/^[a-f0-9-]{36}\.json$/i.test(n))){
   const response=path.join(paths.ipc,'native-results',name);if(fs.existsSync(response))continue;
   const request=JSON.parse(fs.readFileSync(path.join(paths.ipc,'native-actions',name),'utf8'));
   if(request.session!==this.session){publish(response,{ok:false,error:'Previous runtime request; not replayed'});continue;}
   if(request.id!==path.basename(name,'.json')||typeof request.save!=='boolean'||typeof request.quit!=='boolean'||(!request.save&&!request.quit)){
    publish(response,{ok:false,error:'Invalid native lifecycle request'});continue;
   }
   this.busy=true;
   try{
    if(request.quit){this.beginShutdown(request);return;}
    const checkpoint=await this.checkpoints.saveAndWait();
    const result={ok:true,saved:true,checkpoint,restored:false};publish(response,result);
    const completed=await evaluate(`LMExecution completeNativeAction: ${literal(request.id)} result: (STONJSON fromString: ${literal(JSON.stringify(result))})`,'native-save-complete');
    if(!completed.ok)throw Error(JSON.stringify(completed));
   }catch(error){
    const result={ok:false,error:error.message};publish(response,result);
    await evaluate(`LMExecution completeNativeAction: ${literal(request.id)} result: (STONJSON fromString: ${literal(JSON.stringify(result))})`,'native-save-failed').catch(()=>{});
    throw error;
   }finally{this.busy=false;}
  }
 }
 completeQuit(request,checkpoint){
  publish(path.join(paths.ipc,'native-results',request.id+'.json'),{ok:true,saved:request.save,checkpoint});
 }
}
