// Deliberate live check. It sends one model request with synthetic inputs on its own session.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {evaluate} from '../../src/tools/runtime-client.mjs';
import {root,paths} from '../../src/tools/paths.mjs';

const token=randomUUID();
const filename=`object-invocation-${token}.json`;
const output=path.join(root,'tests/results',filename);
const testConversation=process.argv.includes('--conversation');
const start=await evaluate(`[
 | client report |
 client := LMCodexClient new clientKey: 'object-probe-${token}'; yourself.
 report := [
  | caller candidates rules result conversation message |
  ${testConversation ? `
  conversation := LMConversation new.
  conversation instVarNamed: #client put: client.
  message := Dictionary new at: 'text' put: '请只回复四个汉字：对象通过'; yourself.
  result := conversation answer: message.
  { true. result = '对象通过'.
   (LoomPendingInvocations includesKey: (client lastResponse at: 'id')) not }
  ` : `
  caller := Object newAnonymousSubclass.
  caller compile: 'chooseUsing: client candidates: candidates rules: rules preferFirst: preferFirst
   | choice |
   preferFirst ifTrue: [
    "Return a Dictionary. At the key given in rules at: #resultKey, put the exact FIRST candidate. Include #site -> #first."
    choice := client selectCandidateFrom: candidates accordingTo: rules ] ifFalse: [
    "Return a Dictionary. At the key given in rules at: #resultKey, put the exact LAST candidate. Include #site -> #last."
    choice := client selectCandidateFrom: candidates accordingTo: rules ].
   ^ choice'.
  candidates := OrderedCollection with: Object new with: Object new.
  rules := Dictionary new at: #resultKey put: #chosen; yourself.
  result := caller new chooseUsing: client candidates: candidates rules: rules preferFirst: false.
  { true. (result isKindOf: Dictionary). (result at: #chosen) == candidates last.
   (result at: #site) = #last.
   (LoomPendingInvocations includesKey: (client lastResponse at: 'id')) not }
  `}
 ] on: Error do: [ :error | { false. error messageText } ].
 (ExperimentRoot / 'tests' / 'results' / '${filename}') writeStreamDo: [ :out |
  out nextPutAll: (STONJSON toString: (Dictionary new
   at: 'checks' put: report;
   at: 'requestId' put: (client lastResponse ifNotNil: [ :receipt | receipt at: 'id' ]);
   at: 'threadId' put: client threadId;
   yourself)); truncate: out position ].
] fork. true`.replace(/\r?\n/g,'\r'),'live-object-invocation');
assert.equal(start.ok,true,JSON.stringify(start));
const deadline=Date.now()+240000;
while(!fs.existsSync(output)) {
  if(Date.now()>deadline)throw new Error('Timed out waiting for the object invocation test receipt');
  await delay(400);
}
const receipt=JSON.parse(fs.readFileSync(output,'utf8'));
assert.ok(receipt.checks.every(value=>value===true),JSON.stringify(receipt));
assert.ok(receipt.requestId&&receipt.threadId,JSON.stringify(receipt));
const request=JSON.parse(fs.readFileSync(path.join(paths.ipc,'codex-requests',receipt.requestId+'.json'),'utf8'));
assert.equal(request.objectInvocation,true);
assert.equal(request.prompt,'Loom 调用了你。');
console.log(JSON.stringify({output,...receipt}));
