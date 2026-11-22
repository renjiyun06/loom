import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {spawn,spawnSync} from 'node:child_process';
import {once} from 'node:events';
import {root} from '../src/tools/paths.mjs';

const powershell=path.join(process.env.SystemRoot,'System32/WindowsPowerShell/v1.0/powershell.exe');
test('Windows PowerShell 5.1 launcher reads UTF-8 names without corrupting configuration',async()=>{
 const base=path.join(root,'ipc/temp');fs.mkdirSync(base,{recursive:true});
 const fixture=fs.mkdtempSync(path.join(base,'launcher-encoding-'));
 const engineName='test-engine.exe';
 const engine=path.join(fixture,engineName);
 const dummy=path.join(fixture,'main.cjs');
 let child;
 try{
 fs.mkdirSync(path.join(fixture,'ipc'));fs.mkdirSync(path.join(fixture,'config'));
 fs.copyFileSync(path.join(root,'start.ps1'),path.join(fixture,'start.ps1'));
  fs.linkSync(process.execPath,engine);
  fs.writeFileSync(dummy,'setInterval(()=>{},1000);');
  child=spawn(engine,[dummy,path.join(fixture,'src/runtime/direct-bootstrap.st')],{windowsHide:true,stdio:'ignore'});
  await once(child,'spawn');
  const config={schemaVersion:1,displayName:'织境',gui:true,paths:{ipc:'ipc',logs:'logs',engineExecutable:engineName}};
  const text=JSON.stringify(config,null,2);
  fs.writeFileSync(path.join(fixture,'config/runtime.json'),text,'utf8');
  fs.writeFileSync(path.join(fixture,'ipc/runtime-status.json'),JSON.stringify({pid:child.pid,status:'ready',gui:true,label:'织境'}),'utf8');
  const command=`[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); & '${path.join(fixture,'start.ps1').replaceAll("'","''")}' -Gui`;
  const result=spawnSync(powershell,['-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command',command],{windowsHide:true,encoding:'utf8',timeout:15000});
  assert.equal(result.status,0,result.stderr);
  assert.equal(fs.readFileSync(path.join(fixture,'config/runtime.json'),'utf8'),text);
  assert.equal(JSON.parse(result.stdout).label,'织境');
 }finally{
  if(child?.pid && child.exitCode===null && child.signalCode===null){child.kill();await once(child,'exit');}
  assert.equal(path.dirname(fixture),base);
  assert.equal(fs.realpathSync.native(fixture),fixture);
  fs.rmSync(fixture,{recursive:true,maxRetries:4});
 }
});
