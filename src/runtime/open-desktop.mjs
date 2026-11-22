import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {evaluate} from '../bridge/runtime-client.mjs';

// Desktop opening is an explicit request. A healthy background process does
// not imply that Bloc has a running UI loop or an actual Windows window.
export async function openEnvironment({restoreApplications=false}={}) {
 const id=randomUUID();
 const requested=await evaluate(`| universe requests request |
  (Smalltalk globals at: #LoomGuiEnabled ifAbsent: [ false ])
   ifFalse: [ self error: 'The runtime is not in desktop mode' ].
  requests := Smalltalk globals at: #LoomDesktopRequests ifAbsentPut: [ Dictionary new ].
  request := Dictionary new.
  requests at: '${id}' put: request.
  universe := BlParallelUniverse forHost: BlWinitHost.
  universe defer: [
   [ | worlds world |
    worlds := GtWorld allOpenWorlds select: [ :each | each host isKindOf: BlWinitHost ].
    world := worlds ifEmpty: [ Smalltalk globals at: #LoomDesktopWorld ifAbsent: [ nil ] ] ifNotEmpty: [ worlds first ].
    world ifNil: [ world := GtWorld openDefault ] ifNotNil: [ world isOpened ifFalse: [ world show ] ].
    Smalltalk globals at: #LoomDesktopWorld put: world.
    GtWorld defaultId: world id.
    request at: 'world' put: world.
    world requestNextPulse.
    ${restoreApplications?`(Smalltalk globals at: #LoomApplications ifAbsent: [ nil ])
     ifNotNil: [ :applications | applications restoreIn: world ].`:''}
   ] on: Error do: [ :error | request at: 'error' put: error messageText ] ].
  universe hasUIProcess ifFalse: [ universe startUniverse ].
  true`,'desktop-open-'+id);
 if(!requested.ok)throw Error(JSON.stringify(requested));
 try {
  const deadline=Date.now()+15000;
  while(Date.now()<deadline){
   const response=await evaluate(`| request world host ready |
    request := LoomDesktopRequests at: '${id}'.
    world := request at: 'world' ifAbsent: [ nil ].
    host := world ifNotNil: [ world hostSpace ].
    ready := host notNil and: [ host window notNil and: [ host window isValid ] ].
    Dictionary new
     at: 'error' put: (request at: 'error' ifAbsent: [ nil ]);
     at: 'ready' put: ready;
     at: 'hwnd' put: (ready ifTrue: [ host window hwnd asInteger ] ifFalse: [ nil ]);
     yourself`,'desktop-poll-'+id);
   if(!response.ok)throw Error(JSON.stringify(response));
   if(response.value.error)throw Error(response.value.error);
   if(response.value.ready)return {ok:true,...response.value};
   await new Promise(resolve=>setTimeout(resolve,100));
  }
  throw Error('The desktop did not create a native window');
 } finally {
  await evaluate(`LoomDesktopRequests removeKey: '${id}' ifAbsent: [ ]. true`,'desktop-cleanup-'+id).catch(()=>{});
 }
}

if(process.argv[1]===fileURLToPath(import.meta.url)) {
 try{console.log(JSON.stringify(await openEnvironment()));}
 catch(error){console.error(error.message);process.exitCode=1;}
}
