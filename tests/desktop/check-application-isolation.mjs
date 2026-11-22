// Exercise a complete supervised Loom in a disposable directory.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {root} from '../../src/bridge/paths.mjs';
import {evaluate} from '../../src/bridge/runtime-client.mjs';

const temporary = path.resolve(os.tmpdir());
const fixture = fs.mkdtempSync(path.join(temporary, 'loom-application-isolation-'));
const ipc = path.join(fixture, 'ipc');
const sessionFile = path.join(ipc, 'bridge-ready.json');
const appFile = path.join(ipc, 'application-status.json');
const runtimeLinks = ['node', 'codex', 'gtoolkit'];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let child;

function read(file) {
  if (!fs.existsSync(file)) return undefined;
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
}

async function until(description, check, timeout = 45000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const result = check();
    if (result) return result;
    await sleep(100);
  }
  throw Error(`${description} timed out: ${JSON.stringify({bridge: read(sessionFile), application: read(appFile)})}`);
}

async function gt(source, label) {
  const result = await evaluate(source, label, 20000, ipc);
  assert.equal(result.ok, true, JSON.stringify(result));
  return result.value;
}

try {
  fs.cpSync(path.join(root, 'src'), path.join(fixture, 'src'), {recursive: true});
  fs.mkdirSync(path.join(fixture, 'config'));
  fs.mkdirSync(path.join(fixture, 'runtime'));
  const config = read(path.join(root, 'config/runtime.json'));
  fs.writeFileSync(path.join(fixture, 'config/runtime.json'), JSON.stringify({...config, gui: false}));
  fs.copyFileSync(path.join(root, 'config/codex.json'), path.join(fixture, 'config/codex.json'));
  fs.symlinkSync(path.join(root, 'assets'), path.join(fixture, 'assets'), 'junction');
  for (const name of runtimeLinks) fs.symlinkSync(path.join(root, 'runtime', name), path.join(fixture, 'runtime', name), 'junction');

  const legacy = path.join(fixture, 'state/conversation');
  for (const folder of ['inputs', 'replies']) fs.mkdirSync(path.join(legacy, folder), {recursive: true});
  const id = randomUUID();
  const input = path.join(legacy, 'inputs', id + '.json');
  fs.writeFileSync(input, '{invalid fixture');

  child = spawn(path.join(root, 'runtime/supervisor/supervisor.exe'), [fixture], {cwd: fixture, windowsHide: true});
  const core = await until('bridge readiness', () => {
    const state = read(sessionFile);
    if (state?.status === 'failed') throw Error(state.error);
    return state?.status === 'ready' && state;
  });
  const failed = await until('isolated application failure', () => {
    const status = read(appFile);
    return status?.phase === 'ready' && status.conversation.phase === 'failed' && status;
  });
  assert.equal(failed.voice.phase, 'ready');
  const text = await gt("(LMConversationUI new build collectUpdate) at: 'status'", 'conversation-error-status');
  assert.match(text, /对话存储不可用/);
  const named = await gt("LoomSessions register: 'isolation-check'", 'independent-session');
  assert.equal(named.id, 'isolation-check');

  const createdAt = '2026-11-22T04:45:00.000Z';
  fs.writeFileSync(input, JSON.stringify({id, sequence: 1, text: 'old history', createdAt}));
  fs.writeFileSync(path.join(legacy, 'replies', id + '.json'), JSON.stringify({id, ok: true, text: 'old reply'}));
  await gt('LoomApplications reload. true', 'reload-application');
  const recovered = await until('application reload', () => {
    const status = read(appFile);
    return status?.phase === 'ready' && status.pid !== failed.pid && status.conversation.phase === 'ready' && status;
  });
  const sameCore = read(sessionFile);
  assert.deepEqual([sameCore.pid, sameCore.enginePid, sameCore.codexPid], [core.pid, core.enginePid, core.codexPid]);
  assert.equal(sameCore.status, 'ready');
  assert.equal(recovered.session, failed.session);
  const history = await gt("LoomConversation records collect: [ :record | { record at: 'text'. (record at: 'reply') at: 'text' } ]", 'migrated-history');
  assert.deepEqual(history, [['old history', 'old reply']]);
  fs.writeFileSync(path.join(fixture, 'fixture.txt'), 'attachment example');
  const attachment = await gt(`| id record reference |
   (LoomConversation instVarNamed: #worker) ifNotNil: [ :worker | worker terminate ].
   id := UUID new asString.
   LoomConversation storage: 'submit' options: (Dictionary new
    at: 'id' put: id; at: 'text' put: ''; at: 'createdAt' put: DateAndTime now asString;
    at: 'files' put: { (ExperimentRoot / 'fixture.txt') fullName }; yourself).
   record := LoomConversation nextInput.
   reference := LoomConversation attachment: (record at: 'attachmentIds') first.
   LoomConversation storage: 'reply' options: (Dictionary new at: 'reply' put:
    (Dictionary new at: 'id' put: id; at: 'ok' put: true; at: 'text' put: 'fixture'; yourself); yourself).
   { reference at: 'name'. (LoomConversation fileForAttachment: reference) contents }`, 'attachment-after-reload');
  assert.deepEqual(attachment, ['fixture.txt', 'attachment example']);

  fs.writeFileSync(path.join(ipc, 'stop.json'), '{}');
  const stopped = await until('saved shutdown', () => {
    const state = read(sessionFile);
    if (state?.status === 'failed') throw Error(state.error);
    return state?.status === 'stopped' && state;
  });
  assert.equal(stopped.saved, true);
  await until('supervisor exit', () => child.exitCode !== null || child.signalCode !== null);
  assert.equal(child.exitCode, 0);
  console.log('Conversation migration failure is isolated. The application reloaded without restarting the bridge.');
} catch (error) {
  for (const name of ['logs/service.stderr.log', 'logs/runtime.stderr.log', 'logs/runtime.stdout.log', 'PharoDebug.log']) {
    const file = path.join(fixture, name);
    if (fs.existsSync(file)) console.error(fs.readFileSync(file, 'utf8').split(/\r?\n/).slice(-14).join('\n'));
  }
  throw error;
} finally {
  if (child && child.exitCode === null && child.pid) {
    child.kill();
    await until('fixture supervisor exit', () => child.exitCode !== null || child.signalCode !== null, 10000);
  }
  for (const link of [path.join(fixture, 'assets'), ...runtimeLinks.map(name => path.join(fixture, 'runtime', name))]) {
    if (fs.existsSync(link)) fs.unlinkSync(link);
  }
  assert.equal(path.dirname(fixture), temporary);
  fs.rmSync(fixture, {recursive: true, force: true, maxRetries: 4});
}
