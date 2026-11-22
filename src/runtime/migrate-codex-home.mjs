// Move this installation's old threads into Codex's default store at the first cold start.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {createInterface} from 'node:readline';
import {DatabaseSync} from 'node:sqlite';
import {paths, root} from '../tools/paths.mjs';

const source = path.join(root, 'state/codex');
const receipt = path.join(root, 'state/sessions/codex-home-migrated.json');
const target = path.resolve(process.env.CODEX_HOME?.trim() || path.join(os.homedir(), '.codex'));
const sourceIndex = path.join(source, 'state_5.sqlite');

function threadsToMove() {
  const database = new DatabaseSync(sourceIndex, {readOnly: true});
  try {
    return database.prepare('SELECT id, rollout_path, name FROM threads ORDER BY id').all().map(thread => {
      const recorded = thread.rollout_path;
      const sourceFile = fs.realpathSync.native(recorded).replace(/^\\\\\?\\/, '');
      const relative = path.relative(fs.realpathSync.native(source), sourceFile);
      const parts = relative.split(path.sep);
      if (!['sessions', 'archived_sessions'].includes(parts[0]) || !fs.statSync(sourceFile).isFile() ||
          !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(thread.id) ||
          !path.basename(sourceFile).endsWith(thread.id + '.jsonl')) {
        throw Error('Unexpected Codex rollout for thread ' + thread.id);
      }
      return {id: thread.id, name: thread.name, source: sourceFile, relative};
    });
  } finally {
    database.close();
  }
}

function collectExisting(root, ids) {
  const found = new Map();
  function visit(folder) {
    if (!fs.existsSync(folder)) return;
    for (const child of fs.readdirSync(folder, {withFileTypes: true})) {
      const file = path.join(folder, child.name);
      if (child.isDirectory()) visit(file);
      const id = child.name.slice(-42, -6).toLowerCase();
      if (ids.has(id) && child.name.endsWith('.jsonl')) {
        if (!child.isFile() || found.has(id)) throw Error('Conflicting destination thread ' + id);
        found.set(id, file);
      }
    }
  }
  for (const folder of ['sessions', 'archived_sessions']) visit(path.join(root, folder));
  return found;
}

function copyNewRollout(sourceFile, destination) {
  fs.mkdirSync(path.dirname(destination), {recursive: true});
  const temporary = destination + '.' + randomUUID() + '.tmp';
  try {
    fs.copyFileSync(sourceFile, temporary, fs.constants.COPYFILE_EXCL);
    const fd = fs.openSync(temporary, 'r+');
    try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    try { fs.linkSync(temporary, destination); } catch (error) {
      if (error.code !== 'EEXIST' || !fs.readFileSync(sourceFile).equals(fs.readFileSync(destination))) throw error;
    }
  } finally {
    if (fs.existsSync(temporary)) fs.unlinkSync(temporary);
  }
}

async function verifyWithCodex(threads) {
  const child = spawn(paths.codexExecutable, ['app-server', '--stdio'], {
    cwd: paths.workspace, windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'],
  });
  const lines = createInterface({input: child.stdout});
  const pending = new Map();
  let sequence = 0;
  let processError;
  function fail(error) {
    processError = error;
    for (const handler of pending.values()) handler.reject(error);
  }
  child.once('error', fail);
  child.stdin.on('error', fail);
  child.once('exit', () => fail(Error('Codex App Server exited during migration')));
  lines.on('line', line => {
    const response = JSON.parse(line);
    const handler = pending.get(response.id);
    if (!handler) return;
    if (response.error) handler.reject(Error(handler.method + ': ' + response.error.message));
    else handler.resolve(response.result);
  });
  async function rpc(method, params) {
    if (processError) throw processError;
    const id = ++sequence;
    let timer;
    try {
      return await new Promise((resolve, reject) => {
        timer = setTimeout(() => reject(Error('Codex App Server timed out: ' + method)), 20000);
        pending.set(id, {method, resolve, reject});
        child.stdin.write(JSON.stringify({id, method, params}) + '\n');
      });
    } finally {
      clearTimeout(timer);
      pending.delete(id);
    }
  }
  try {
    await rpc('initialize', {clientInfo: {name: 'loom_migration', version: '1'}, capabilities: {experimentalApi: true}});
    child.stdin.write(JSON.stringify({method: 'initialized'}) + '\n');
    for (const thread of threads) {
      const resumed = await rpc('thread/resume', {threadId: thread.id, excludeTurns: true, cwd: paths.workspace});
      if (resumed.thread?.id !== thread.id) throw Error('Codex returned a different thread during migration');
      if (thread.name && !resumed.thread.name) {
        await rpc('thread/name/set', {threadId: thread.id, name: thread.name});
      }
    }
  } finally {
    child.stdin.end();
    lines.close();
    const stopped = new Promise(resolve => child.once('close', resolve));
    const timer = setTimeout(() => child.kill(), 2000);
    if (child.exitCode === null && child.signalCode === null && child.pid) await stopped;
    clearTimeout(timer);
  }
}

if (fs.existsSync(sourceIndex) && !fs.existsSync(receipt)) {
  if (source.toLowerCase() === target.toLowerCase()) throw Error('Legacy Codex home is still set on the launcher');
  const threads = threadsToMove();
  const existing = collectExisting(target, new Set(threads.map(thread => thread.id.toLowerCase())));
  for (const thread of threads) {
    const existingFile = existing.get(thread.id.toLowerCase());
    if (existingFile && !fs.readFileSync(thread.source).equals(fs.readFileSync(existingFile))) {
      throw Error('Destination thread already has different history: ' + thread.id);
    }
  }
  for (const thread of threads) {
    if (!existing.has(thread.id.toLowerCase())) copyNewRollout(thread.source, path.join(target, thread.relative));
  }
  if (threads.length) await verifyWithCodex(threads);
  fs.mkdirSync(path.dirname(receipt), {recursive: true});
  const temporary = receipt + '.' + randomUUID() + '.tmp';
  fs.writeFileSync(temporary, JSON.stringify({target, threads: threads.length}), {flag: 'wx', flush: true});
  fs.renameSync(temporary, receipt);
  console.log(JSON.stringify({target, migratedThreads: threads.length}));
}
