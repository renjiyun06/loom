import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {root} from '../src/bridge/paths.mjs';
import {VoiceService,durableJSON} from '../src/audio/voice-service.mjs';
import {ConversationStore} from '../src/conversation/store.mjs';
import {parseTranscript} from '../src/audio/xfyun.mjs';
const result={lattice:[{json_1best:JSON.stringify({st:{bg:'3000',ed:'5000',rt:[{ws:[{wb:10,we:70,cw:[{w:'测试',wp:'n'}]}]}]}})}]};
function fixture(state,extra={}) {
 const directory=path.join(root,'tests/results/voice-recovery',randomUUID());
 const id=randomUUID();
 durableJSON(path.join(directory,'state/audio',id,'message.json'),{id,title:'fixture',state,createdAt:new Date().toISOString(),original:'original.wav',...extra});
 return {directory,id};
}
test('completed recognition keeps frame-relative word timing',()=>{
 const parsed=parseTranscript(result);assert.equal(parsed.text,'测试');assert.equal(parsed.segments[0].start,3.1);assert.equal(parsed.segments[0].end,3.7);
});
test('restart queries a persisted order without uploading it again',async()=>{
 const {directory,id}=fixture('processing',{orderId:'existing-order',signatureRandom:'saved-random'});
 let uploads=0,queries=0,notices=0;
 const service=new VoiceService(directory,{provider:{configured:()=>true,upload:async()=>{uploads++;throw Error();},query:async(order,random)=>{assert.equal(order,'existing-order');assert.equal(random,'saved-random');queries++;return {orderInfo:{status:4},orderResult:JSON.stringify(result)};}},notify:async()=>{notices++;}});
 await service.query(service.get(id));await service.close();
 assert.equal(service.get(id).state,'completed');assert.equal(queries,1);assert.equal(uploads,0);assert.equal(notices,1);
 const reopened=new VoiceService(directory,{provider:{configured:()=>true}});
 assert.equal(reopened.get(id).transcript,'测试');assert.equal(reopened.get(id).state,'completed');await reopened.close();
});
test('interrupted upload becomes unknown and neither polling nor retry reuploads',async()=>{
 const {directory,id}=fixture('uploading',{signatureRandom:'saved-random'});let uploads=0;
 const service=new VoiceService(directory,{provider:{configured:()=>true,upload:async()=>{uploads++;}}});
 assert.equal(service.get(id).state,'unknown');assert.throws(()=>service.retry(id),/不确定/);
 await service.poll();assert.equal(uploads,0);await service.close();
});
test('transient query failure retains the same order for retry',async()=>{
 const {directory,id}=fixture('processing',{orderId:'existing-order',signatureRandom:'saved-random'});
 const service=new VoiceService(directory,{provider:{configured:()=>true,query:async()=>{const e=new Error('temporary');e.code='QUERY_RETRY';throw e;}}});
 await service.query(service.get(id));assert.equal(service.get(id).state,'processing');assert.equal(service.get(id).orderId,'existing-order');await service.close();
});
test('recording never restarts the microphone after a runtime crash',async()=>{
 const {directory,id}=fixture('recording');const service=new VoiceService(directory,{provider:{configured:()=>true}});
 assert.equal(service.get(id).state,'draft');assert.equal(service.recorder,null);await service.close();
});

test('pause and resume control the same recorder and publish its retained waveform',async()=>{
 const {directory,id}=fixture('draft');
 const service=new VoiceService(directory,{provider:{configured:()=>false}});
 const commands=[];
 const recorder={id,state:'recording',levels:[20,42],child:{stdin:{write(command){
   commands.push(command);recorder.state=command==='pause\n'?'paused':'recording';
 }}}};
 service.recorder=recorder;
 await service.command({action:'pause',audioId:id});
 assert.deepEqual(JSON.parse(fs.readFileSync(path.join(service.ipc,'meter.json'))),{audioId:id,state:'paused',levels:[20,42]});
 await service.command({action:'resume',audioId:id});
 assert.equal(service.recorder,recorder);
 assert.deepEqual(commands,['pause\n','resume\n']);
 service.recorder=null;await service.close();
});

test('stopping capture preserves a draft and cancel discards only an unsent recording',async()=>{
 const {directory,id}=fixture('draft',{source:'microphone'});
 const service=new VoiceService(directory,{provider:{configured:()=>false}});
 const wav=service.file(service.get(id),'original.wav');
 fs.writeFileSync(wav,'recording fixture');
 assert.deepEqual(await service.command({action:'stop',audioId:id}),{audioId:id,state:'draft',error:undefined});
 await service.poll();
 assert.equal(service.get(id).state,'draft');
 assert.equal(service.get(id).messageId,undefined);
 await service.command({action:'cancel',audioId:id});
 assert.equal(fs.existsSync(wav),false);
 assert.throws(()=>service.get(id),/音频不存在/);
 await service.close();
});

test('a migrated audio message starts one order and survives a failed GT wake',async t=>{
 const {directory,id}=fixture('draft',{source:'microphone'});
 const messageId=randomUUID();
 durableJSON(path.join(directory,'state/conversation/inputs',`${messageId}.json`),{id:messageId,audioId:id,sequence:1,text:''});
 const conversations=new ConversationStore(path.join(directory,'state/conversation'));
 t.after(()=>conversations.close());
 let uploads=0,wakes=0;
 const service=new VoiceService(directory,{
  audioMessages:()=>conversations.audioMessages(),
  provider:{configured:()=>true,
   upload:async()=>{uploads++;return {orderId:'one-order'};},
   query:async()=>({orderInfo:{status:4},orderResult:JSON.stringify(result)}),
  },
  notify:async()=>{if(++wakes===1)throw Error('GT mailbox unavailable');},
 });
 service.probe=async()=>5;
 service.convert=async()=>path.join(directory,'synthetic.flac');
 await service.poll();
 const job=service.get(id);
 await job.operation;
 assert.equal(job.messageId,messageId);
 assert.equal(job.state,'processing');
 assert.equal(uploads,1);
 await service.query(job);
 assert.equal(job.state,'completed');
 assert.equal(job.transcript,'测试');
 assert.equal(service.wakePending,true);
 await service.poll();
 assert.equal(service.wakePending,false);
 assert.equal(wakes,2);
 assert.equal(uploads,1);
 await service.close();
});
