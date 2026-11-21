import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {paths} from './paths.mjs';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
export function archivePendingCommands(directory=paths.ipc) {
  const inbox=path.join(directory,'mailbox');
  if(!fs.existsSync(inbox))return 0;
  const archive=path.join(paths.logs,'interrupted-commands');
  const results=path.join(directory,'results');
  fs.mkdirSync(archive,{recursive:true});fs.mkdirSync(results,{recursive:true});
  let count=0;
  for(const name of fs.readdirSync(inbox).filter(name=>name.endsWith('.st'))) {
    fs.renameSync(path.join(inbox,name),path.join(archive,`${Date.now()}-${name}`));
    const response=path.join(results,name.replace(/\.st$/,'.json'));
    if(!fs.existsSync(response))fs.writeFileSync(response,JSON.stringify({ok:false,error:'RUNTIME_INTERRUPTED',message:'Previous runtime command was interrupted and was not replayed'}));
    count++;
  }
  return count;
}
export async function evaluate(code, label = 'eval', timeout = 20000, directory = paths.ipc) {
  const id = `${Date.now()}-${label}`;
  fs.mkdirSync(path.join(directory, 'mailbox'), {recursive: true});
  const pending = path.join(directory, 'mailbox', `${id}.tmp`);
  const archive=directory===paths.ipc?path.join(paths.logs,'commands'):path.join(directory,'commands');
  fs.mkdirSync(archive, {recursive: true});
  fs.writeFileSync(path.join(archive, `${id}.st`), code);
  fs.writeFileSync(pending, code);
  fs.renameSync(pending, pending.replace(/\.tmp$/, '.st'));
  const target = path.join(directory, 'results', `${id}.json`);
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (fs.existsSync(target)) {
      let response;
      try { response = JSON.parse(fs.readFileSync(target, 'utf8')); }
      catch { await sleep(30); continue; }
      return response;
    }
    await sleep(30);
  }
  throw new Error(`Timeout: ${label}`);
}
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const code = process.argv[2] === '--file'
    ? fs.readFileSync(process.argv[3], 'utf8') : process.argv.slice(2).join(' ');
  console.log(JSON.stringify(await evaluate(code), null, 2));
}
