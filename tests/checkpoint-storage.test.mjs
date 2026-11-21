import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {CheckpointStorage,hashFile} from '../src/bridge/checkpoint-storage.mjs';
import {root} from '../src/bridge/paths.mjs';

const base=path.join(root,'tests/results/checkpoint-storage-unit');
fs.mkdirSync(base,{recursive:true});
function setup(){
 const directory=fs.mkdtempSync(path.join(base,'case-'));
 fs.mkdirSync(path.join(directory,'state/runtime/checkpoints'),{recursive:true});
 return new CheckpointStorage(directory);
}
function pair(storage){
 const id=randomUUID(),directory=path.join(storage.directory,id);
 fs.mkdirSync(directory);
 const image=path.join(directory,'resume.image'),changes=path.join(directory,'resume.changes');
 fs.writeFileSync(image,'image '+id);fs.writeFileSync(changes,'changes '+id);
 return {id,image:path.relative(storage.root,image),sha256:hashFile(image),changesSha256:hashFile(changes)};
}
function select(storage,pointer){fs.writeFileSync(storage.pointerFile,JSON.stringify(pointer));}

test('only the selected valid pair survives, independent of directory timestamps',()=>{
 const storage=setup(),current=pair(storage),old=pair(storage),partial=randomUUID();
 select(storage,current);fs.mkdirSync(path.join(storage.directory,partial));
 const report=storage.prune();
 assert.equal(report.retained,current.id);assert.equal(report.removed.length,2);
 assert.deepEqual(fs.readdirSync(storage.directory),[current.id]);
 assert.equal(storage.verify().pointer.id,current.id);
});
test('failed or incomplete replacement leaves the previous committed recovery intact',()=>{
 const storage=setup(),current=pair(storage);select(storage,current);
 const unfinished=path.join(storage.directory,randomUUID());fs.mkdirSync(unfinished);
 fs.writeFileSync(path.join(unfinished,'resume.image'),'unfinished');
 assert.equal(storage.verify().pointer.id,current.id);
 assert.ok(fs.existsSync(path.join(storage.root,current.image)));
});
test('corrupt image, corrupt changes, or absent changes prevent every cleanup',()=>{
 for(const damage of ['image','changes','missing']){
  const storage=setup(),current=pair(storage),old=pair(storage);select(storage,current);
  const file=path.join(storage.root,current.image).replace(/\.image$/,damage==='image'?'.image':'.changes');
  if(damage==='missing')fs.unlinkSync(file);else fs.appendFileSync(file,'corrupt');
  assert.throws(()=>storage.prune());
  assert.ok(fs.existsSync(path.join(storage.root,old.image)));
 }
});
test('an active old image is protected until execution has moved to working',()=>{
 const storage=setup(),current=pair(storage),old=pair(storage);select(storage,current);
 const active=path.join(storage.directory,old.id,'main.image');fs.writeFileSync(active,'active');
 assert.equal(storage.prune({protectedImages:[active]}).removed.length,0);
 assert.equal(storage.prune({protectedImages:[path.join(storage.root,'state/runtime/working/main.image')]}).removed.length,1);
});
test('cleanup unlinks nested junctions without deleting their external target',()=>{
 const storage=setup(),current=pair(storage),old=pair(storage);select(storage,current);
 const outside=fs.mkdtempSync(path.join(base,'external-'));fs.writeFileSync(path.join(outside,'keep'),'vendor resources');
 fs.symlinkSync(outside,path.join(storage.directory,old.id,'gt-extra'),'junction');
 storage.prune();assert.equal(fs.readFileSync(path.join(outside,'keep'),'utf8'),'vendor resources');
});
test('redirected checkpoint folders and unrelated directories are never followed or deleted',()=>{
 const storage=setup(),current=pair(storage);select(storage,current);
 const outside=fs.mkdtempSync(path.join(base,'external-'));fs.writeFileSync(path.join(outside,'keep'),'protected');
 const redirected=path.join(storage.directory,randomUUID());fs.symlinkSync(outside,redirected,'junction');
 const unrelated=path.join(storage.directory,'manual-backup');fs.mkdirSync(unrelated);
 storage.prune();assert.ok(fs.existsSync(redirected));assert.ok(fs.existsSync(unrelated));
 assert.ok(fs.existsSync(path.join(outside,'keep')));
});
test('a pointer outside the checkpoint tree cannot authorize cleanup',()=>{
 const storage=setup(),current=pair(storage);select(storage,{...current,image:'../../outside.image'});
 assert.throws(()=>storage.prune(),/path is invalid/);
 assert.ok(fs.existsSync(path.join(storage.root,current.image)));
});
test('existing image-only hashes remain readable for migration',()=>{
 const storage=setup(),current=pair(storage);delete current.changesSha256;select(storage,current);
 assert.equal(storage.verify().pointer.id,current.id);
});
