import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {root} from '../src/bridge/paths.mjs';
import {VoiceService,durableJSON} from '../src/audio/voice-service.mjs';
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
