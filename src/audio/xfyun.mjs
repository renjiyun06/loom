import fs from 'node:fs';
import {createHmac, randomBytes} from 'node:crypto';

export class SpeechError extends Error {
  constructor(code, message) { super(message); this.code=code; }
}
export function randomSignature() { return randomBytes(12).toString('base64url').replace(/[-_]/g,'A'); }
export function parseTranscript(value) {
  try {
    const result=typeof value==='string'?JSON.parse(value):value;
    const lattice=result?.lattice??result?.lattice2;
    if(!Array.isArray(lattice))throw Error();
    const segments=lattice.map(entry=>{
      const {st}=typeof entry.json_1best==='string'?JSON.parse(entry.json_1best):entry.json_1best;
      const words=st.rt.flatMap(part=>part.ws);
      const text=words.map(word=>word.cw?.[0]?.w??'').join('').trim();
      const spoken=words.filter(word=>!['p','g'].includes(word.cw?.[0]?.wp)&&/[\p{L}\p{N}]/u.test(word.cw?.[0]?.w??''));
      const bg=Number(st.bg),ed=Number(st.ed);
      const start=bg+(Number(spoken[0]?.wb)||0)*10;
      const end=spoken.at(-1)?.we!==undefined?Math.min(ed,bg+Number(spoken.at(-1).we)*10):ed;
      return {start:start/1000,end:end/1000,text};
    }).filter(segment=>segment.text&&Number.isFinite(segment.start)&&Number.isFinite(segment.end));
    return {segments,text:segments.map(segment=>segment.text).join('\n')};
  } catch { throw new SpeechError('RESULT_INVALID','讯飞转录结果无法解析，原始结果已保留。'); }
}
export class Xfyun {
  constructor(configFile,{send=fetch}={}) { this.configFile=configFile; this.send=send; }
  credentials() {
    let config;
    try {config=JSON.parse(fs.readFileSync(this.configFile,'utf8'));}catch{}
    if(!['appId','apiKey','apiSecret'].every(key=>typeof config?.[key]==='string'&&config[key].trim()))
      throw new SpeechError('NOT_CONFIGURED','尚未配置讯飞录音文件转写。');
    return config;
  }
  configured() {try {this.credentials();return true;}catch {return false;}}
  async request(endpoint,fields,body) {
    const credentials=this.credentials();
    const params=new URLSearchParams({...fields,accessKeyId:credentials.apiKey,dateTime:new Date().toISOString().slice(0,19)+'+0000'});
    params.sort();
    const signature=createHmac('sha1',credentials.apiSecret).update(params.toString()).digest('base64');
    const upload=endpoint==='upload';
    let response,payload;
    try {
      response=await this.send('https://office-api-ist-dx.iflyaisol.com/v2/'+endpoint+'?'+params,{
        method:'POST',redirect:'error',signal:AbortSignal.timeout(upload?180000:20000),body,
        ...(upload?{duplex:'half'}:{}),headers:{'Content-Type':upload?'application/octet-stream':'application/json',signature},
      });
      payload=await response.json();
    }catch {
      throw new SpeechError(upload?'UPLOAD_UNKNOWN':'QUERY_RETRY',upload?'上传结果不确定，请核对讯飞订单，未自动重传。':'暂时无法查询讯飞订单，将继续查询。');
    }
    if(!response.ok||String(payload?.code)!=='000000') {
      if(response.status>=500)throw new SpeechError(upload?'UPLOAD_UNKNOWN':'QUERY_RETRY','讯飞服务暂时不可用，请核对既有订单。');
      const code=/^\d{6}$/.test(String(payload?.code))?String(payload.code):'unknown';
      throw new SpeechError('PROVIDER_REJECTED','讯飞拒绝请求（'+code+'），请核对服务权限和额度。');
    }
    return payload.content;
  }
  async upload(file,signatureRandom) {
    const {appId}=this.credentials();
    const size=fs.statSync(file).size;
    if(size>500*1024*1024)throw new SpeechError('TOO_LARGE','转写音频超过500MB。');
    const body=fs.createReadStream(file);
    try {
      const result=await this.request('upload',{appId,signatureRandom,fileName:'audio.flac',fileSize:String(size),durationCheckDisable:'true',language:'autodialect',eng_smoothproc:'false',eng_colloqproc:'false'},body);
      if(typeof result?.orderId!=='string'||!result.orderId)throw new SpeechError('UPLOAD_UNKNOWN','讯飞没有返回订单号，请核对控制台订单。');
      return result;
    } finally {body.destroy();}
  }
  query(orderId,signatureRandom) {return this.request('getResult',{orderId,signatureRandom,resultType:'transfer'},'{}');}
}
