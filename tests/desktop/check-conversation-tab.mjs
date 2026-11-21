// Deliberate live UI regression. Does not send text or create model turns.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {evaluate} from '../../src/bridge/runtime-client.mjs';
import {root} from '../../src/bridge/paths.mjs';

async function run(code) {
 const reply=await evaluate(code,'conversation-tab-test');
 assert.equal(reply.ok,true,JSON.stringify(reply));
 return reply.value;
}
async function ui(code) {
 await run(`Smalltalk globals at: #LoomTabTestReceipt put: nil.
 (BlParallelUniverse forHost: BlWinitHost) defer: [
  [ ${code}. Smalltalk globals at: #LoomTabTestReceipt put: true ]
   on: Error do: [ :e | Smalltalk globals at: #LoomTabTestReceipt put: e messageText ] ]. true`);
 const deadline=Date.now()+10000;
 while(Date.now()<deadline) {
  const value=await run('LoomTabTestReceipt');
  if(value!==null){assert.equal(value,true);return;}
  await new Promise(resolve=>setTimeout(resolve,100));
 }
 throw Error('UI action did not finish');
}
const resultFile=path.join(root,'tests/results/conversation-tab.json');
if(process.argv.includes('--after-restart')) {
 const retained=await run(`{
  LMConversationUI featureVersion >= 3.
  LoomConversationWindow isOpen.
  LoomConversationWindow tab isSelected.
  (LoomConversationWindow instVarNamed: 'input') text asString = (LoomTabTestBefore at: 'draft').
  LoomCodex threadId = (LoomTabTestBefore at: 'thread').
  LoomConversation records size = (LoomTabTestBefore at: 'messages').
  LoomConversationWindow presentationSpace isOpened not.
  (GtWorld allOpenWorlds select: [ :w | w host isKindOf: BlWinitHost ]) size = 1 }`);
 assert.ok(retained.every(value=>value===true),JSON.stringify(retained));
 const evidence=JSON.parse(fs.readFileSync(resultFile,'utf8'));
 evidence.restart={checkedAt:new Date().toISOString(),retained};
 fs.writeFileSync(resultFile,JSON.stringify(evidence,null,2));
 await run('Smalltalk globals removeKey: #LoomTabTestBefore ifAbsent: []. Smalltalk globals removeKey: #LoomTabTestReceipt ifAbsent: []. true');
 console.log(JSON.stringify(evidence,null,2));
} else {
 await run(`Smalltalk globals at: #LoomTabTestBefore put: (Dictionary new
  at: 'draft' put: (LoomConversationWindow instVarNamed: 'input') text asString copy;
  at: 'thread' put: LoomCodex threadId;
  at: 'messages' put: LoomConversation records size; yourself). true`);
 await ui('LoomConversationWindow show. LoomConversationWindow show');
 const opened=await run(`| world labels entryCount nativeCount |
 world := LoomConversationWindow hostWorld. labels := OrderedCollection new.
 entryCount := 0. nativeCount := 0.
 world root withAllChildrenBreadthFirstDo: [ :e |
  e id asString = '#loomConversationEntry' ifTrue: [ entryCount := entryCount + 1 ].
  (e id asString includesSubstring: 'chat-registry--button') ifTrue: [ nativeCount := nativeCount + 1 ] ].
 (LoomConversationWindow instVarNamed: 'root') withAllChildrenBreadthFirstDo: [ :e |
  (e isKindOf: BrButton) ifTrue: [ labels add: e label asString ] ].
 { (world tabGroup tabs count: [ :t | t model == LoomConversationWindow presentationSpace ]) = 1.
  entryCount = 1. nativeCount = 0.
  (labels asArray = #('运行对象' '保存' '发送')).
  LoomConversationWindow presentationSpace isOpened not }`);
 assert.ok(opened.every(value=>value===true),JSON.stringify(opened));
 await ui('LoomConversationWindow hostWorld tabGroup viewModel removeTab: LoomConversationWindow tab');
 await new Promise(resolve=>setTimeout(resolve,700));
 const closed=await run(`{ LoomConversationWindow isOpen not.
  (LoomConversationWindow instVarNamed: 'poller') isTerminated.
  (LoomConversationWindow instVarNamed: 'input') text asString = (LoomTabTestBefore at: 'draft') }`);
 assert.ok(closed.every(value=>value===true),JSON.stringify(closed));
 await ui('LoomConversation open');
 const reopened=await run(`{ LoomConversationWindow isOpen.
  LoomConversationWindow tab isSelected.
  (LoomConversationWindow instVarNamed: 'input') text asString = (LoomTabTestBefore at: 'draft').
  LoomCodex threadId = (LoomTabTestBefore at: 'thread').
  LoomConversation records size = (LoomTabTestBefore at: 'messages') }`);
 assert.ok(reopened.every(value=>value===true),JSON.stringify(reopened));
 const evidence={checkedAt:new Date().toISOString(),opened,closed,reopened,noModelTurnSent:true};
 fs.writeFileSync(resultFile,JSON.stringify(evidence,null,2));
 console.log(JSON.stringify(evidence,null,2));
}
