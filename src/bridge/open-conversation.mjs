import {randomUUID} from 'node:crypto';
import {evaluate} from './runtime-client.mjs';
import {openEnvironment} from './open-environment.mjs';
await openEnvironment();
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
