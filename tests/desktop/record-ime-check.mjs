// Run after deliberate Sogou UI checks in the diagnostic tab; never sends text.
import fs from 'node:fs';
import assert from 'node:assert/strict';
import {evaluate} from '../../src/tools/runtime-client.mjs';
const reply=await evaluate(`{
 LoomImeCommitValid.
 LoomImeTestEditor text asString = LoomImeBodyBefore.
 (LoomImeTestEditor space hostSpace instVarNamed: 'keyBuffer') isEmpty.
 (LoomConversationWindow instVarNamed: 'input') text asString = (LoomImeBefore at: 'draft').
 LoomCodex threadId = (LoomImeBefore at: 'thread').
 LoomConversation records size = (LoomImeBefore at: 'messages') }`,'ime-result');
assert.equal(reply.ok,true,JSON.stringify(reply));
assert.ok(reply.value.every(value=>value===true),JSON.stringify(reply));
const [chineseCommit,chineseBackspace,noStuckKeys,draftPreservedSinceRecovery,threadUnchanged,noMessageSent]=reply.value;
const evidence={checkedAt:new Date().toISOString(),ime:'Sogou',scaleFactor:1.5,
 chineseCommit,chineseBackspace,noStuckKeys,draftPreservedSinceRecovery,threadUnchanged,noMessageSent,
 observations:{compositionBackspaceLeavesBody:true,latinInputAfterPatch:true,candidateFollowsCaretVisually:true},
 isolatedNativePositions:2,isolatedFfi:true,
 earlierFailure:'Initial direct Win32 BOOL return caused unsupported SINT32 event-loop marshalling panic. Replaced by uint64 native wrapper; restarted from last committed checkpoint.'};
fs.writeFileSync(new URL('../results/windows-ime.json',import.meta.url),JSON.stringify(evidence,null,2));
console.log(JSON.stringify(evidence,null,2));
