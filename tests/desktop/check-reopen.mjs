// Live regression: close the empty desktop, retain the runtime, then launch the
// actual Windows shortcut. Run deliberately; this is not a unit-test fixture.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {root} from '../../src/bridge/paths.mjs';
import {evaluate} from '../../src/bridge/runtime-client.mjs';

const read=relative=>JSON.parse(fs.readFileSync(path.join(root,relative),'utf8'));
const before=read('ipc/bridge-ready.json');
assert.equal(before.status,'ready');
const errorLog=path.join(root,'logs/launcher-error.log');
const errorsBefore=fs.existsSync(errorLog)?fs.statSync(errorLog).size:0;
const marker=Date.now();
async function inspect(){
 const result=await evaluate(`{
  (BlParallelUniverse forHost: BlWinitHost) hasUIProcess.
  (GtWorld allOpenWorlds select: [ :world | world host isKindOf: BlWinitHost ]) size.
  LoomCodex threadId }`,'desktop-test-state');
 assert.equal(result.ok,true,JSON.stringify(result));return result.value;
}
async function until(check){
 const deadline=Date.now()+20000;
 while(Date.now()<deadline){const result=await check();if(result)return result;await new Promise(resolve=>setTimeout(resolve,100));}
 throw Error('Desktop state did not arrive');
}

const closed=await evaluate(`| universe |
 universe := BlParallelUniverse forHost: BlWinitHost.
 universe defer: [
  (GtWorld allOpenWorlds select: [ :world | world host isKindOf: BlWinitHost ])
   do: [ :world | world removeShutdownListener. world close ] ].
 true`,'desktop-test-close');
assert.equal(closed.ok,true);
const stoppedUI=await until(async()=>{const s=await inspect();return !s[0] && s[1]===0?s:null;});

const shortcut=path.join(process.env.USERPROFILE,'Desktop/织境.lnk');
assert.ok(fs.existsSync(shortcut));
const command=`$shell=New-Object -ComObject WScript.Shell; [void]$shell.Run('"${shortcut.replaceAll("'","''")}"',1,$false)`;
const launched=spawnSync(path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe'),
 ['-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(command,'utf16le').toString('base64')],{windowsHide:true,encoding:'utf8',timeout:10000});
assert.equal(launched.status,0,launched.stderr);
const receipt=await until(async()=>{
 const file=path.join(root,'logs/launcher-desktop.json');if(!fs.existsSync(file))return null;
 const r=read('logs/launcher-desktop.json');return Date.parse(r.openedAt)>=marker?r:null;
});
const reopened=await inspect();
assert.equal(reopened[0],true);assert.equal(reopened[1],1);
assert.equal(receipt.enginePid,before.enginePid);assert.equal(receipt.visible,true);
assert.equal(receipt.minimized,false);
assert.equal(read('ipc/bridge-ready.json').pid,before.pid);
assert.equal(fs.existsSync(errorLog)?fs.statSync(errorLog).size:0,errorsBefore);
await evaluate(`(BlParallelUniverse forHost: BlWinitHost) defer: [
 (GtWorld allOpenWorlds select: [ :world | world host isKindOf: BlWinitHost ])
  do: [ :world | world addShutdownListener ] ]. true`,'desktop-test-restore-close-handler');
const evidence={checkedAt:new Date().toISOString(),shortcut,stoppedUI,reopened,receipt,processReused:true,noNewErrors:true};
fs.writeFileSync(path.join(root,'tests/results/desktop-reopen.json'),JSON.stringify(evidence,null,2));
console.log(JSON.stringify(evidence,null,2));
