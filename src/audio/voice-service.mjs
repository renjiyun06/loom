import fs from 'node:fs';
import path from 'node:path';
import {spawn,execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {randomUUID} from 'node:crypto';
import {createInterface} from 'node:readline';
import {atomicJSON,replaceFileSync} from '../bridge/atomic-files.mjs';
import {Xfyun,SpeechError,randomSignature,parseTranscript} from './xfyun.mjs';
const exec=promisify(execFile);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const uuid=value=>typeof value==='string'&&/^[a-f0-9-]{36}$/i.test(value);
export function durableJSON(file,value) {
  fs.mkdirSync(path.dirname(file),{recursive:true});
  const temporary=file+'.tmp';
  const fd=fs.openSync(temporary,'w');
  try {fs.writeFileSync(fd,JSON.stringify(value,null,2));fs.fsyncSync(fd);}finally {fs.closeSync(fd);}
  replaceFileSync(temporary,file);
}
export class VoiceService {
  constructor(root,{provider,notify=async()=>{},audioMessages=()=>[]}={}) {
    this.root=root; this.directory=path.join(root,'state/audio');this.ipc=path.join(root,'ipc/voice');
    this.host=path.join(root,'runtime/audio/AudioHost.exe');this.media=path.join(root,'runtime/media');
    this.provider=provider??new Xfyun(path.join(root,'config/xfyun.local.json'));
    this.notify=notify;this.audioMessages=audioMessages;this.wakePending=false;this.jobs=new Map();this.recorder=null;this.player=null;this.busy=false;this.closed=false;
    for(const folder of [this.directory,path.join(this.ipc,'requests'),path.join(this.ipc,'results')])fs.mkdirSync(folder,{recursive:true});
    // Requests without receipts belong to the old runtime and are never replayed.
    for(const name of fs.readdirSync(path.join(this.ipc,'requests')).filter(n=>n.endsWith('.json'))) {
      const result=path.join(this.ipc,'results',name);
      if(!fs.existsSync(result))durableJSON(result,{ok:false,error:'操作在上一次运行时中断，请核对当前音频状态。'});
    }
    for(const entry of fs.readdirSync(this.directory,{withFileTypes:true}).filter(e=>e.isDirectory()&&uuid(e.name))) {
      const file=path.join(this.directory,entry.name,'message.json');
      if(!fs.existsSync(file))continue;
      const job=JSON.parse(fs.readFileSync(file,'utf8'));
      if(job.state==='uploading') {job.state='unknown';job.error='上次上传中断，未自动重传。请核对讯飞订单。';}
      if(job.state==='recording') {job.state='draft';job.error='录音因运行环境停止而结束，已保留现有音频。';}
      if(job.state==='preparing')job.state='queued';
      this.jobs.set(job.id,job);this.save(job);
    }
    this.publish();
    this.publishMeter();
  }
  file(job,name) {return path.join(this.directory,job.id,name);}
  get(id) {if(!uuid(id)||!this.jobs.has(id))throw Error('音频不存在。');return this.jobs.get(id);}
  save(job) {job.updatedAt=new Date().toISOString();const {operation,...stored}=job;durableJSON(this.file(job,'message.json'),stored);this.publish();}
  publish() {
    const value={configured:this.provider.configured(),recordingId:this.recorder?.id??null,playingId:this.player?.id??null,jobs:[...this.jobs.values()].map(({operation,...job})=>({...job,elapsed:job.state==='recording'?Math.floor((Date.now()-Date.parse(job.createdAt))/1000):job.duration??0}))};
    const serialized=JSON.stringify(value);
    if(this.lastProjection===serialized)return;
    durableJSON(path.join(this.directory,'index.json'),value);this.lastProjection=serialized;
  }
  makeJob(title,original) {
    const job={id:randomUUID(),title,state:'draft',createdAt:new Date().toISOString(),original};
    this.jobs.set(job.id,job);this.save(job);return job;
  }
  async probe(file) {
    const {stdout}=await exec(path.join(this.media,'ffprobe.exe'),['-v','error','-show_entries','format=duration','-of','json',file],{windowsHide:true,timeout:20000,maxBuffer:1024*1024});
    const duration=Number(JSON.parse(stdout).format.duration);
    if(!Number.isFinite(duration)||duration<=0||duration>18000)throw Error('音频为空或超过5小时。');
    return duration;
  }
  async convert(job,name,format) {
    const target=this.file(job,name);
    if(fs.existsSync(target))return target;
    const temporary=target+'.partial';
    await exec(path.join(this.media,'ffmpeg.exe'),['-nostdin','-v','error','-y','-protocol_whitelist','file,pipe','-i',this.file(job,job.original),'-vn','-ac','1','-ar','16000','-sample_fmt','s16','-f',format,temporary],{windowsHide:true,timeout:300000,maxBuffer:1024*1024});
    fs.renameSync(temporary,target);return target;
  }
  async record() {
    if(this.recorder)throw Error('已有录音正在进行。');
    this.stopPlayback();
    const job=this.makeJob('录音 '+new Date().toLocaleString('zh-CN'), 'original.wav');
    job.state='recording';job.source='microphone';
    const child=spawn(this.host,['record',this.file(job,job.original)],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    const recorder={id:job.id,child,state:'starting',levels:[],pipeError:null};this.recorder=recorder;
    const lines=createInterface({input:child.stdout});
    lines.on('line',line=>{
      if(line==='recording'||line==='resumed')recorder.state='recording';
      if(line==='paused')recorder.state='paused';
      const level=/^level (\d{1,3})$/.exec(line);
      if(level){
        recorder.levels.push(Math.min(100,Number(level[1])));
        if(recorder.levels.length>24)recorder.levels.shift();
      }
    });
    child.stdin.on('error',error=>{recorder.pipeError=error;});
    child.stderr.resume();
    const meterTimer=setInterval(()=>this.publishMeter(),100);
    recorder.finished=new Promise(resolve=>{
      child.once('error',error=>{recorder.pipeError=error;});
      child.once('close',async code=>{
        lines.close();clearInterval(meterTimer);recorder.state='closed';
        job.state='draft';
        try {job.duration=await this.probe(this.file(job,job.original));if(code!==0)job.error='录音已中断，现有音频已保留。';}
        catch {job.state='failed';job.error='录音设备不可用或音频为空。';}
        if(this.recorder===recorder)this.recorder=null;
        try {this.save(job);}catch(error){recorder.saveError=error;}
        this.publishMeter();resolve(job);
      });
    });
    this.save(job);
    try {await this.waitForRecorder(recorder,'recording',10000);}
    catch {await this.stopRecording(job.id);throw Error('无法启动麦克风录音，请核对设备和 Windows 麦克风权限。');}
    return {audioId:job.id};
  }
  publishMeter() {
    const recorder=this.recorder;
    const value={audioId:recorder?.id??null,state:recorder?.state??null,levels:recorder?.levels??[]};
    const serialized=JSON.stringify(value);
    if(this.lastMeter===serialized)return;
    // The meter is a transient projection. A reader can keep its previous frame on a sharing violation.
    try {atomicJSON(path.join(this.ipc,'meter.json'),value);this.lastMeter=serialized;}
    catch(error){if(!['EPERM','EACCES','EBUSY'].includes(error.code))console.error('Voice meter:',error.message);}
  }
  async waitForRecorder(recorder,state,timeout) {
    const deadline=Date.now()+timeout;
    while(recorder.state!==state){
      if(recorder.pipeError||recorder.state==='closed'||Date.now()>=deadline)throw Error('录音设备未响应。');
      await sleep(25);
    }
    this.publishMeter();
  }
  async controlRecording(id,action) {
    const recorder=this.recorder;
    if(!recorder||recorder.id!==id)throw Error('录音已经结束。');
    recorder.child.stdin.write(action+'\n');
    await this.waitForRecorder(recorder,action==='pause'?'paused':'recording',5000);
    return {audioId:id};
  }
  async stopRecording(id) {
    const recorder=this.recorder;
    if(!recorder){
      const job=id?this.get(id):null;
      return job?{audioId:job.id,state:job.state,error:job.error}:{};
    }
    if(id&&recorder.id!==id)throw Error('录音已经结束。');
    if(!recorder.child.stdin.destroyed&&!recorder.child.stdin.writableEnded)recorder.child.stdin.end('stop\n');
    const timeout=setTimeout(()=>{
      if(recorder.state!=='closed')recorder.child.kill();
    },5000);
    let job;
    try {job=await recorder.finished;}finally{clearTimeout(timeout);}
    if(recorder.saveError)throw recorder.saveError;
    return {audioId:job.id,state:job.state,error:job.error};
  }
  async cancelRecording(id) {
    const job=this.get(id);
    if(this.recorder?.id===id)await this.stopRecording(id);
    if(job.source!=='microphone'||job.messageId||!['draft','failed'].includes(job.state))throw Error('此录音无法取消。');
    fs.rmSync(this.file(job,job.original),{force:true});
    fs.rmSync(this.file(job,'message.json'),{force:true});
    fs.rmdirSync(this.file(job,''));
    this.jobs.delete(id);this.publish();
    return {audioId:id};
  }
  async import(file) {
    const source=path.resolve(file);
    const duration=await this.probe(source);
    const extension=path.extname(source).toLowerCase();
    if(!/^\.[a-z0-9]{1,8}$/.test(extension))throw Error('不支持的音频文件名。');
    const job=this.makeJob(path.basename(source),'original'+extension);
    fs.copyFileSync(source,this.file(job,job.original));job.duration=duration;this.save(job);return {audioId:job.id};
  }
  async pick() {
    const {stdout}=await exec(this.host,['pick'],{windowsHide:true,timeout:600000,maxBuffer:32768});
    return stdout.trim()?this.import(stdout.trim()):{};
  }
  stopPlayback() {
    const player=this.player;if(!player)return;
    if(!player.child.stdin.destroyed&&!player.child.stdin.writableEnded)player.child.stdin.end('stop\n');
    this.player=null;this.publish();
  }
  async play(id) {
    if(this.recorder)throw Error('请先停止录音再试听。');
    this.stopPlayback();const job=this.get(id);
    const target=job.source==='microphone'?this.file(job,job.original):await this.convert(job,'preview.wav','wav');
    const child=spawn(this.host,['play',target],{windowsHide:true,stdio:['pipe','pipe','pipe']});
    let error='',output='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>error+=b);
    child.stdin.on('error',()=>{error='无法向播放设备发送命令。';});
    const player={id,child};this.player=player;
    const clear=()=>{if(this.player===player){this.player=null;this.publish();}};
    child.once('error',()=>{error='无法启动播放工具。';clear();});
    child.once('exit',code=>{if(code!==0)error='播放设备返回错误。';clear();});
    this.publish();
    const deadline=Date.now()+5000;
    while(!output.includes('playing')){
      if(error||Date.now()>deadline){
        if(this.player===player)this.stopPlayback();
        throw Error('音频播放失败，请核对 Windows 输出设备。');
      }
      await sleep(30);
    }
    return {audioId:id};
  }
  retry(id) {
    const job=this.get(id);
    if(job.state==='unknown')throw Error('上传结果不确定，请先在控制台核对订单；不会自动重传。');
    if(job.state==='recording')throw Error('请先停止录音。');
    if(job.state==='completed')return {};
    job.state=job.orderId?'processing':'queued';delete job.error;job.nextPoll=0;this.save(job);return {};
  }
  async submit(id,messageId) {
    const job=this.get(id);if(job.state==='recording')throw Error('请先停止录音。');
    if(job.messageId&&job.messageId!==messageId)throw Error('此音频已经发送。');
    job.messageId=messageId;
    if(job.state==='draft')job.state='queued';this.save(job);return {};
  }
  async transcribe(job) {
    try {
      this.provider.credentials?.();
      job.state='preparing';delete job.error;this.save(job);
      job.duration=await this.probe(this.file(job,job.original));
      const target=await this.convert(job,'transcription.flac','flac');
      job.signatureRandom=randomSignature();job.state='uploading';this.save(job);
      const order=await this.provider.upload(target,job.signatureRandom);
      job.orderId=order.orderId;job.state='processing';job.nextPoll=Date.now()+2500;this.save(job);
    }catch(error){job.state=error.code==='UPLOAD_UNKNOWN'?'unknown':'failed';job.error=error instanceof SpeechError?error.message:'音频预处理失败，请核对原音文件。';this.save(job);}
  }
  async wakeConversation() {
    try {await this.notify();this.wakePending=false;}
    catch {this.wakePending=true;}
  }
  async query(job) {
    try {
      const content=await this.provider.query(job.orderId,job.signatureRandom);
      durableJSON(this.file(job,'provider-result.json'),content);
      const state=Number(content?.orderInfo?.status);
      if(state===0||state===3){delete job.error;return;}
      const silent=state===-1&&Number(content.orderInfo.failType)===6;
      if(state!==4&&!silent)throw new SpeechError('ORDER_FAILED','讯飞未能完成此音频的转录。');
      const result=silent?{segments:[],text:''}:parseTranscript(content.orderResult);
      job.transcript=result.text;job.segments=result.segments;job.state='completed';delete job.error;
    }catch(error){
      job.error=error instanceof SpeechError?error.message:'查询转录结果失败。';
      if(error.code!=='QUERY_RETRY')job.state='failed';
    }finally{job.nextPoll=Date.now()+5000;this.save(job);}
    if(job.state==='completed')await this.wakeConversation();
  }
  async command(request) {
    switch(request.action) {
      case 'record':return this.record();
      case 'pause':return this.controlRecording(request.audioId,'pause');
      case 'resume':return this.controlRecording(request.audioId,'resume');
      case 'stop':return this.stopRecording(request.audioId);
      case 'cancel':return this.cancelRecording(request.audioId);
      case 'import':return this.import(request.file);
      case 'pick':return this.pick();
      case 'play':return this.play(request.audioId);
      case 'stop-playback':this.stopPlayback();return {};
      case 'retry':return this.retry(request.audioId);
      case 'submit':return this.submit(request.audioId,request.messageId);
      case 'close-window':await this.stopRecording();this.stopPlayback();return {};
      default:throw Error('未知音频操作。');
    }
  }
  async poll() {
    if(this.busy||this.closed)return;this.busy=true;
    try {
      for(const name of fs.readdirSync(path.join(this.ipc,'requests')).filter(n=>/^[a-f0-9-]{36}\.json$/i.test(n))) {
        const receipt=path.join(this.ipc,'results',name);if(fs.existsSync(receipt))continue;
        try {const request=JSON.parse(fs.readFileSync(path.join(this.ipc,'requests',name),'utf8'));durableJSON(receipt,{ok:true,...await this.command(request)});}
        catch(error){durableJSON(receipt,{ok:false,error:error.message});}
      }
      // The message store can recover work interrupted before the recording was queued.
      for(const input of this.audioMessages()) {
        const job=this.jobs.get(input.audioId);
        if(job&&!job.messageId)await this.submit(job.id,input.id);
      }
      for(const job of this.jobs.values()) {
        if(job.state==='queued'&&!job.operation)job.operation=this.transcribe(job).finally(()=>{delete job.operation;});
        if(job.state==='processing'&&Date.now()>=(job.nextPoll??0)&&!job.operation)job.operation=this.query(job).finally(()=>{delete job.operation;});
      }
      if(this.wakePending)await this.wakeConversation();
      this.publish();
    }finally{this.busy=false;}
  }
  async close() {this.closed=true;await this.stopRecording();this.stopPlayback();}
}
