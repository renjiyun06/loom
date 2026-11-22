// Exercise a complete supervised Loom in a disposable directory.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {root} from '../../src/bridge/paths.mjs';
import {evaluate} from '../../src/bridge/runtime-client.mjs';
import {CheckpointStorage} from '../../src/bridge/checkpoint-storage.mjs';

const temporary = path.resolve(os.tmpdir());
const fixture = fs.mkdtempSync(path.join(temporary, 'loom-application-isolation-'));
const ipc = path.join(fixture, 'ipc');
const sessionFile = path.join(ipc, 'bridge-ready.json');
const codexHome = path.join(fixture, 'app-server-home');
const runtimeLinks = ['node', 'codex', 'gtoolkit', 'audio', 'media'];
const mockCodex = process.argv.includes('--mock-codex');
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
  throw Error(`${description} timed out: ${JSON.stringify(read(sessionFile))}`);
}

async function gt(source, label, timeout = 20000) {
  const result = await evaluate(source, label, timeout, ipc);
  assert.equal(result.ok, true, JSON.stringify(result));
  return result.value;
}

async function waitForApplication(name, phase) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const status = await gt(`(Smalltalk globals at: #LoomApplications ifAbsent: [ nil ])
      ifNotNil: [ :apps | (apps respondsTo: #statusFor:) ifTrue: [ apps statusFor: '${name}' ] ]`, 'application-status');
    if (status?.phase === phase) return status;
    if (status?.phase === 'failed' && phase !== 'failed') throw Error(`${status.error} (${status.errorAt ?? name})`);
    await sleep(200);
  }
  const trace = await gt("| frames | frames := Smalltalk globals at: #LoomApplicationLoadTrace ifAbsent: [ #() ]. String lf join: (frames first: (frames size min: 16))",
    'application-load-trace');
  throw Error(`Application ${name} did not report ${phase}: ${trace}`);
}

async function start(previousPid) {
  child = spawn(path.join(fixture, 'runtime/LoomSupervisor.exe'), [fixture], {
    cwd: fixture, windowsHide: true, env: {...process.env, CODEX_HOME: codexHome, CODEX_SQLITE_HOME: codexHome},
  });
  return until('bridge readiness', () => {
    if (child.exitCode !== null || child.signalCode !== null) throw Error('Supervisor quit before readiness: ' + JSON.stringify(read(sessionFile)));
    const state = read(sessionFile);
    if (!state || state.pid === previousPid) return false;
    if (state.status === 'failed') throw Error(state.error);
    return state.status === 'ready' && state;
  });
}

async function stoppedAfter(save) {
  const stopped = await until('runtime shutdown', () => {
    const state = read(sessionFile);
    if (state?.status === 'failed') throw Error(state.error);
    return state?.status === 'stopped' && state;
  });
  assert.equal(stopped.saved, save);
  await until('supervisor exit', () => child.exitCode !== null || child.signalCode !== null);
  assert.equal(child.exitCode, 0);
}

async function submitModel(source, label) {
  const output = path.join(fixture, label + '.json');
  await gt(`[ | result |
   result := [ Dictionary new at: 'ok' put: true; at: 'value' put: [
    ${source}
   ] value; yourself ] on: Error do: [ :error |
    Dictionary new at: 'ok' put: false; at: 'error' put: error messageText; yourself ].
   LMPlatformTools writeJSON: result to: ExperimentRoot / '${label}.json'
  ] fork. true`, label);
  return () => until(label, () => read(output), 150000);
}

try {
  fs.cpSync(path.join(root, 'src'), path.join(fixture, 'src'), {recursive: true});
  fs.mkdirSync(path.join(fixture, 'tests'));
  fs.copyFileSync(path.join(root, 'tests/gt-voice-recovery.st'), path.join(fixture, 'tests/gt-voice-recovery.st'));
  fs.copyFileSync(path.join(root, 'tests/gt-codex-contract.st'), path.join(fixture, 'tests/gt-codex-contract.st'));
  fs.mkdirSync(path.join(fixture, 'config'));
  fs.mkdirSync(path.join(fixture, 'runtime'));
  fs.mkdirSync(codexHome);
  fs.copyFileSync(path.join(root, 'runtime/supervisor/LoomSupervisor.exe'), path.join(fixture, 'runtime/LoomSupervisor.exe'));
  const config = read(path.join(root, 'config/runtime.json'));
  if (mockCodex) {
    config.paths.codexExecutable = 'runtime/fake-codex.exe';
    execFileSync(path.join(process.env.SystemRoot, 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'),
      ['/nologo', '/target:exe', '/r:System.Web.Extensions.dll', '/out:' + path.join(fixture, config.paths.codexExecutable),
        path.join(root, 'tests/desktop/FakeCodexAppServer.cs')], {windowsHide: true});
  }
  fs.writeFileSync(path.join(fixture, 'config/runtime.json'), JSON.stringify({...config, gui: false}));
  fs.copyFileSync(path.join(root, 'config/codex.json'), path.join(fixture, 'config/codex.json'));
  fs.symlinkSync(path.join(root, 'assets'), path.join(fixture, 'assets'), 'junction');
  for (const name of runtimeLinks) fs.symlinkSync(path.join(root, 'runtime', name), path.join(fixture, 'runtime', name), 'junction');

  const legacy = path.join(fixture, 'state/conversation');
  for (const folder of ['inputs', 'replies']) fs.mkdirSync(path.join(legacy, folder), {recursive: true});
  const id = randomUUID();
  const input = path.join(legacy, 'inputs', id + '.json');
  fs.writeFileSync(input, '{invalid fixture');

  const core = await start();
  assert.equal(core.pid, core.enginePid);
  assert.equal(core.transport, 'GT / Codex App Server stdio');
  assert.equal(core.codexHome, undefined);
  if (mockCodex) {
    const models = read(path.join(ipc, 'codex-options.json')).models;
    assert.ok(models.some(model => model.id === 'offline' && model.label === 'Offline fixture'));
  } else assert.ok(fs.existsSync(path.join(codexHome, 'state_5.sqlite')));
  await waitForApplication('conversation-model', 'ready');
  await waitForApplication('conversation', 'failed');
  await waitForApplication('voice', 'ready');
  await waitForApplication('conversation-view', 'ready');
  const text = await gt("(LMConversationUI new build collectUpdate) at: 'status'", 'conversation-error-status');
  assert.match(text, /对话存储不可用/);
  const named = await gt("LoomSessions register: 'isolation-check'", 'independent-session');
  assert.equal(named.id, 'isolation-check');

  const createdAt = '2026-11-22T04:45:00.000Z';
  fs.writeFileSync(input, JSON.stringify({id, sequence: 1, text: "旧记录'内容", createdAt}));
  fs.writeFileSync(path.join(legacy, 'replies', id + '.json'), JSON.stringify({id, ok: true, text: 'old reply'}));
  await gt('Smalltalk globals at: #LoomTestReload put: LoomApplications reload. true', 'reload-application');
  const reloadDeadline = Date.now() + 30000;
  while (!(await gt('LoomTestReload isTerminated', 'reload-progress'))) {
    if (Date.now() >= reloadDeadline) throw Error('The GT reload did not finish');
    await sleep(100);
  }
  await waitForApplication('conversation', 'ready');
  await waitForApplication('voice', 'ready');
  await waitForApplication('conversation-view', 'ready');
  const sameCore = read(sessionFile);
  assert.deepEqual([sameCore.pid, sameCore.enginePid, sameCore.codexPid], [core.pid, core.enginePid, core.codexPid]);
  assert.equal(sameCore.status, 'ready');
  const history = await gt("LoomConversation records collect: [ :record | { record at: 'text'. (record at: 'reply') at: 'text' } ]", 'migrated-history');
  assert.deepEqual(history, [["旧记录'内容", 'old reply']]);
  fs.writeFileSync(path.join(fixture, 'fixture.txt'), 'attachment example');
  const attachment = await gt(`| id record reference |
   (LoomConversation instVarNamed: #worker) ifNotNil: [ :worker | worker terminate ].
   id := UUID new asString.
   LoomConversation storage: 'submit' options: (Dictionary new
    at: 'id' put: id; at: 'text' put: ''; at: 'createdAt' put: DateAndTime now asString;
    at: 'files' put: { (ExperimentRoot / 'fixture.txt') fullName }; yourself).
   (ExperimentRoot / 'fixture.txt') delete.
   record := LoomConversation nextInput.
   reference := LoomConversation attachment: (record at: 'attachmentIds') first.
   LoomConversation storage: 'reply' options: (Dictionary new at: 'reply' put:
    (Dictionary new at: 'id' put: id; at: 'ok' put: true; at: 'text' put: 'fixture'; yourself); yourself).
   { reference at: 'name'. (LoomConversation fileForAttachment: reference) contents }`, 'attachment-after-reload');
  assert.deepEqual(attachment, ['fixture.txt', 'attachment example']);
  fs.writeFileSync(path.join(fixture, 'valid.txt'), 'partial import fixture');
  const rejected = await gt(`[
   LoomConversation storage: 'submit' options: (Dictionary new
    at: 'id' put: UUID new asString; at: 'text' put: ''; at: 'createdAt' put: DateAndTime now asString;
    at: 'files' put: { (ExperimentRoot / 'valid.txt') fullName. (ExperimentRoot / 'absent.txt') fullName }; yourself).
   false
  ] on: Error do: [ :error | true ]`, 'failed-attachment-copy');
  assert.equal(rejected, true);
  assert.equal(fs.readdirSync(path.join(legacy, 'attachments')).length, 1);
  const audio = await gt("Smalltalk compiler evaluate: (ExperimentRoot / 'tests' / 'gt-voice-recovery.st') contents",
    'native-voice-recovery', 60000);
  assert.equal(audio, 'GT voice recovery passed');
  let thread, uncertain;
  if (mockCodex) {
    const nativeContract = await gt("Smalltalk compiler evaluate: (ExperimentRoot / 'tests' / 'gt-codex-contract.st') contents",
      'native-codex-contract');
    assert.equal(nativeContract, 'GT Codex contract passed');
    const objectCall = await submitModel("(LoomSessions session: 'isolation-check') fixtureCall: '活对象'", 'object-call');
    assert.deepEqual(await objectCall(), {ok: true, value: {session: 'isolation-check', argument: '活对象'}});
    const bound = await gt("LoomSessions show: 'isolation-check'", 'durable-binding');
    thread = bound.threadId;
    assert.match(thread, /^fixture-/);
    assert.equal(bound.threads.length, 1);
    const activity = await gt(`| page |
     page := (LoomNativeCodexHost instVarNamed: #registry)
      activityPageFrom: nil limit: 30 previous: 30 focus: nil session: 'isolation-check' managedOnly: true.
     (page at: 'items') collect: [ :item | item at: 'type' ]
    `, 'direct-codex-activity');
    assert.deepEqual(activity, ['agentMessage', 'dynamicToolCall']);
    const cancelled = await submitModel("(LoomSessions session: 'isolation-check') ask: 'mock-active'", 'cancelled-call');
    const deadline = Date.now() + 90000;
    let running;
    while (!(running?.call?.turnId)) {
      if (Date.now() >= deadline) throw Error('The test turn did not start');
      running = await gt("LoomSessions show: 'isolation-check'", 'model-pending');
      await sleep(200);
    }
    const stopped = await gt("LoomSessions stop: 'isolation-check'", 'cancel-direct-codex');
    assert.deepEqual(stopped.cancelledRequests, [running.call.requestId]);
    assert.match((await cancelled()).error, /interrupted/);
    uncertain = randomUUID();
    await gt(`(LoomNativeCodexHost instVarNamed: #registry) beginCall:
     (Dictionary new at: 'id' put: '${uncertain}'; at: 'action' put: 'ask';
      at: 'prompt' put: 'uncertain fixture'; at: 'clientKey' put: 'loom.isolation-check'; yourself).
      true`, 'uncertain-durable-call');
  }

  fs.writeFileSync(path.join(ipc, 'stop.json'), '{}');
  await stoppedAfter(true);
  const sealed = new CheckpointStorage(fixture).verify();
  assert.equal(fs.readdirSync(path.join(fixture, 'state/runtime/checkpoints')).length, 1);
  assert.equal(path.resolve(read(sessionFile).image), sealed.image);
  fs.writeFileSync(path.join(fixture, 'main.changes'), '\n');
  await start(core.pid);
  await waitForApplication('conversation', 'ready');
  await waitForApplication('voice', 'ready');
  const restored = await gt(`{
   LoomConversation records size.
   ((LMVoice index at: 'jobs') anySatisfy: [ :job | (job at: 'title') = 'offline.wav' ]).
   (LoomSessions show: 'isolation-check') at: 'id'.
   LMConversation comment includesSubstring: 'conversation program'
  }`, 'restored-applications');
  assert.deepEqual(restored, [2, true, 'isolation-check', true]);
  const recoveredTabs = await gt(`| world contents tabs before after freshPrompt |
   world := GtWorld new.
   contents := world instVarNamed: #worldElement.
   tabs := contents childNamed: #'gt-world--tabs'.
   contents userData at: #loomDesktopSession put: 'previous-runtime'.
   contents showShutdownPrompt.
   before := world tabGroup == tabs.
   LoomApplications restoreIn: world.
   after := contents childWithId: GtWorldShutdownPromptId ifFound: [ :prompt | false ] ifNone: [ true ].
   contents showShutdownPrompt.
   LoomApplications restoreIn: world.
   freshPrompt := contents childWithId: GtWorldShutdownPromptId ifFound: [ :prompt | true ] ifNone: [ false ].
   { before. after. world tabGroup == tabs. freshPrompt }
  `, 'tabs-behind-restored-shutdown-prompt');
  assert.deepEqual(recoveredTabs, [true, true, true, true]);
  fs.appendFileSync(path.join(fixture, 'src/runtime/conversation-db.st'), ".\nLMConversationStore compile: 'reloadFixtureMarker ^ 7'.\n");
  await gt('Smalltalk globals at: #LoomTestReload put: LoomApplications reload. true', 'reload-after-restart');
  const markerDeadline = Date.now() + 30000;
  while (!(await gt('LMConversationStore includesSelector: #reloadFixtureMarker', 'reloaded-marker'))) {
    if (Date.now() >= markerDeadline) throw Error('Source changed on disk, but the restored GT did not compile it');
    await sleep(150);
  }
  assert.equal(fs.readFileSync(path.join(fixture, 'main.changes'), 'utf8'), '\n');
  if (mockCodex) {
    const interrupted = read(path.join(ipc, 'codex-responses', uncertain + '.json'));
    assert.equal(interrupted.ok, false);
    assert.match(interrupted.error, /uncertain outcome/);
    const resumed = await submitModel("(LoomSessions session: 'isolation-check') ask: '会话续接'", 'resumed-model-call');
    assert.deepEqual(await resumed(), {ok: true, value: '会话续接 回执'});
    assert.equal((await gt("LoomSessions show: 'isolation-check'", 'resumed-binding')).threadId, thread);
    await gt(`| view |
     view := LMConversationUI new build.
     Smalltalk globals at: #LoomTestEchoView put: view.
     (view instVarNamed: #input) text: 'fixture echo after restart'.
     view sendMessage.
     true`, 'send-from-restored-runtime');
    const echoDeadline = Date.now() + 30000;
    for (;;) {
      const messages = await gt(`| messages |
       messages := LoomTestEchoView collectUpdate at: 'messages'.
       (messages last: 2) collect: [ :item | { item at: 'role'. item at: 'text' } ]`, 'read-echo-and-reply');
      if (messages[1][1] === 'fixture echo after restart reply') {
        assert.deepEqual(messages, [['user', 'fixture echo after restart'], ['assistant', 'fixture echo after restart reply']]);
        break;
      }
      if (Date.now() >= echoDeadline) throw Error('The restored conversation did not echo the message and reply: ' + JSON.stringify(messages));
      await sleep(200);
    }
  }
  await gt('[ Smalltalk snapshot: false andQuit: true ] fork. true', 'discard-fixture-runtime');
  await stoppedAfter(false);
  console.log('GT hot reload, fault isolation, attachments, native audio and checkpoint restart passed.');
} catch (error) {
  for (const name of ['voice-test/test-progress.json', 'logs/supervisor.log', 'logs/codex.stderr.log',
    'logs/service.stderr.log', 'logs/runtime.stderr.log', 'logs/runtime.stdout.log', 'PharoDebug.log']) {
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
