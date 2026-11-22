import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {atomicJSON} from './atomic-files.mjs';

const controlTimeout=10000;
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));

export async function sessionCommand(directory,action,sessionId) {
  const status=JSON.parse(fs.readFileSync(path.join(directory,'runtime-status.json'),'utf8'));
  if(status.status!=='ready'||!status.sessionControl)throw new Error('Loom session management is not ready');
  const name=randomUUID()+'.json';
  const receipt=path.join(directory,'session-responses',name);
  atomicJSON(path.join(directory,'session-requests',name),{instance:status.sessionControl,action,sessionId});
  const deadline=Date.now()+controlTimeout;
  while(!fs.existsSync(receipt)) {
    if(Date.now()>deadline)throw new Error('Loom session command timed out');
    await sleep(40);
  }
  const response=JSON.parse(fs.readFileSync(receipt,'utf8'));
  fs.unlinkSync(receipt);
  if(!response.ok)throw new Error(response.error);
  return response.value;
}
