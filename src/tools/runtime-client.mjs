import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {paths} from './paths.mjs';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
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
