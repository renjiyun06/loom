import {randomUUID} from 'node:crypto';
import {evaluate} from './runtime-client.mjs';
import {openEnvironment} from '../runtime/open-desktop.mjs';
await openEnvironment();
const startupDeadline=Date.now()+20000;
for (;;) {
 const available=await evaluate("(Smalltalk globals includesKey: #LoomConversation) and: [ Smalltalk globals includesKey: #LMConversationUI ]",'conversation-available');
 if(available.ok && available.value)break;
 if(Date.now()>=startupDeadline)throw Error('The Loom conversation application did not load');
 await new Promise(resolve=>setTimeout(resolve,100));
}
const id=randomUUID();
const requested=await evaluate(`BlHost pickHost universe defer: [
 [ | presenter |
   presenter := LoomConversation open.
   Smalltalk globals at: #ConversationOpenReceipt put:
    (Dictionary new at: 'id' put: '${id}'; at: 'ok' put: true; yourself)
 ] on: Error do: [ :error |
   Smalltalk globals at: #ConversationOpenReceipt put:
    (Dictionary new at: 'id' put: '${id}'; at: 'ok' put: false;
     at: 'error' put: error messageText; yourself) ] ]. true`,'open-conversation-'+id);
if(!requested.ok)throw Error(JSON.stringify(requested));
const deadline=Date.now()+10000;
let receipt;
while(Date.now()<deadline){
 const result=await evaluate("Smalltalk globals at: #ConversationOpenReceipt ifAbsent: [ nil ]",'open-receipt-'+id);
 if(result.ok&&result.value?.id===id){receipt=result.value;break;}
 await new Promise(resolve=>setTimeout(resolve,100));
}
if(!receipt?.ok)throw Error(receipt?.error??'The Loom UI did not confirm opening the conversation');
console.log(JSON.stringify(receipt));
