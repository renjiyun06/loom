import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {evaluate} from './runtime-client.mjs';
import {paths} from './paths.mjs';
const live=paths.ipc;
export async function askCodex(prompt,{receiver='LoomCodex'}={}) {
  if(!prompt.trim())throw new Error('Pass the text to send from Loom to Codex');
  if(!/^[A-Za-z][A-Za-z0-9_]*$/.test(receiver))throw new Error('Invalid Loom client global');
  const literal="'"+prompt.replaceAll("'","''")+"'";
  const invocation=`[ [ Smalltalk globals at: #LastCodexReply put: (${receiver} ask: ${literal}) ] on: Error do: [ :e | Smalltalk globals at: #LastCodexError put: e messageText ] ] fork. 'started'`;
  const start=await evaluate("Smalltalk globals removeKey: #LastCodexReply ifAbsent: []. Smalltalk globals removeKey: #LastCodexError ifAbsent: []. "+invocation,'ask-real-codex',20000,live);
  if(!start.ok)throw new Error(JSON.stringify(start));
  const deadline=Date.now()+620000;
  while(Date.now()<deadline) {
    const status=await evaluate(`Dictionary new at: 'finished' put: ((Smalltalk globals includesKey: #LastCodexReply) or: [Smalltalk globals includesKey: #LastCodexError]); at: 'text' put: (Smalltalk globals at: #LastCodexReply ifAbsent: [nil]); at: 'error' put: (Smalltalk globals at: #LastCodexError ifAbsent: [nil]); at: 'response' put: ${receiver} lastResponse; yourself`,'poll-codex',20000,live);
    if(!status.ok)throw new Error(JSON.stringify(status));
    if(status.value.finished)return status.value;
    await new Promise(resolve=>setTimeout(resolve,1000));
  }
  throw new Error('Timed out awaiting Loom client completion');
}
if(process.argv[1]===fileURLToPath(import.meta.url)) {
  const result=await askCodex(process.argv.slice(2).join(' '));
  console.log(JSON.stringify(result,null,2));
  if(result.error)process.exitCode=1;
}
