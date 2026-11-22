// Read-only comparison around the deliberately scheduled storage upgrade.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {evaluate} from '../../src/tools/runtime-client.mjs';
import {root} from '../../src/tools/paths.mjs';
const directory=path.join(root,'tests/results/checkpoint-optimization');
fs.mkdirSync(directory,{recursive:true});
const reply=await evaluate(`| classes |
 classes := (Smalltalk globals keys select: [ :key |
  (key asString beginsWith: 'LM') and: [ (Smalltalk globals at: key) isClass ] ]) sorted.
 { LoomCodex threadId. LoomConversation records.
  (LoomConversationWindow instVarNamed: 'input') text asString.
  LMConversationUI featureVersion. LoomConversationWindow isOpen.
  classes collect: [ :key | | cls |
   cls := Smalltalk globals at: key.
   { key asString. cls instVarNames asArray.
    (cls methods sorted: [ :a :b | a selector < b selector ]) collect: [ :m | {m selector asString. m sourceCode} ] as: Array.
    (cls class methods sorted: [ :a :b | a selector < b selector ]) collect: [ :m | {m selector asString. m sourceCode} ] as: Array }
  ] as: Array }`,'preserve-loom-state');
assert.equal(reply.ok,true,JSON.stringify(reply));
const [thread,records,draft,uiVersion,tabOpen,classes]=reply.value;
const hash=value=>createHash('sha256').update(JSON.stringify(value)).digest('hex');
const state={thread,messages:records.length,messageHash:hash(records),draftLength:draft.length,draftHash:hash(draft),uiVersion,tabOpen,classes:classes.map(row=>({name:row[0],hash:hash(row)}))};
if(process.argv.includes('--baseline')){
 fs.writeFileSync(path.join(directory,'preservation-before.json'),JSON.stringify(state,null,2));
 console.log(JSON.stringify({captured:true,thread,messages:state.messages,uiVersion,classes:classes.length}));
}else{
 const before=JSON.parse(fs.readFileSync(path.join(directory,'preservation-before.json'),'utf8'));
 assert.deepEqual(state,before,'Loom objects or saved conversation changed across storage maintenance');
 fs.writeFileSync(path.join(directory,'preservation-after.json'),JSON.stringify({checkedAt:new Date().toISOString(),unchanged:true,...state},null,2));
 console.log(JSON.stringify({unchanged:true,thread,messages:state.messages,uiVersion,classes:classes.length}));
}
