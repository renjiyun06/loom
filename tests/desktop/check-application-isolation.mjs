// Exercise a complete supervised Loom in a disposable directory.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {root} from '../../src/tools/paths.mjs';
import {evaluate} from '../../src/tools/runtime-client.mjs';
import {CheckpointStorage} from '../../src/tools/checkpoint-storage.mjs';

const temporary = path.resolve(os.tmpdir());
const fixture = fs.mkdtempSync(path.join(temporary, 'loom-application-isolation-'));
const ipc = path.join(fixture, 'ipc');
const sessionFile = path.join(ipc, 'runtime-status.json');
const codexHome = path.join(fixture, 'app-server-home');
const runtimeLinks = ['node', 'codex', 'gtoolkit', 'audio', 'media'];
const mockCodex = process.argv.includes('--mock-codex');
const supervisorBinary = process.env.LOOM_TEST_SUPERVISOR ?? path.join(root, 'runtime/supervisor/LoomSupervisor.exe');
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
  return until('runtime readiness', () => {
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
  fs.copyFileSync(supervisorBinary, path.join(fixture, 'runtime/LoomSupervisor.exe'));
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
  const attachment = await gt(`| id record reference view payload before waiting blocked reset after |
   (LoomConversation instVarNamed: #worker) ifNotNil: [ :worker | worker terminate ].
   view := LMConversationUI new build.
   view applyUpdate: view collectUpdate.
   before := view canSendMessage.
   id := LoomConversation submit: '' files: { (ExperimentRoot / 'fixture.txt') fullName }.
   (ExperimentRoot / 'fixture.txt') delete.
   payload := view collectUpdate.
   waiting := (payload at: 'sendAllowed') not and: [ (((payload at: 'messages') last) at: 'role') = 'user' ].
   blocked := [ LoomConversation submit: 'reject before the worker claims the first message'. nil ]
    on: Error do: [ :error | error messageText ].
   record := LoomConversation nextInput.
   reference := LoomConversation attachment: (record at: 'attachmentIds') first.
   LoomConversation instVarNamed: #currentId put: id.
   [
    view applyUpdate: view collectUpdate.
    reset := ((view instVarNamed: #status) parent childNamed: #loomSendMessage) states isDisabled.
   ] ensure: [ LoomConversation instVarNamed: #currentId put: nil ].
   LoomConversation storage: 'reply' options: (Dictionary new at: 'reply' put:
    (Dictionary new at: 'id' put: id; at: 'ok' put: true; at: 'text' put: 'fixture'; yourself); yourself).
   view applyUpdate: view collectUpdate.
   after := ((view instVarNamed: #status) parent childNamed: #loomSendMessage) states isEnabled.
   { reference at: 'name'. (LoomConversation fileForAttachment: reference) contents.
     before. waiting. blocked. reset. after }`, 'attachment-and-single-send-after-reload');
  assert.deepEqual(attachment, ['fixture.txt', 'attachment example', true, true, '请等当前消息处理完成后再发送', true, true]);
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
    await gt("LoomApplications load: 'weixin.st'. true", 'load-weixin');
    const weixinReply = await submitModel("LMGtWeixin new answer: (Dictionary new at: 'id' put: 'fixture-id'; at: 'text' put: '微信'; yourself)",
      'weixin-main-session');
    assert.deepEqual(await weixinReply(), {ok: true, value: '微信 reply'});
    const weixinCallCount = "LoomNativeCodexHost registry database: [ :db | (db execute: 'SELECT COUNT(*) FROM calls') first asInteger ]";
    const beforeVoice = await gt(weixinCallCount, 'weixin-before-voice');
    const weixinVoice = await submitModel(`| entry message |
      entry := LMGtWeixin new.
      message := Dictionary new at: 'id' put: 'voice-id';
      at: 'text' put: 'fixture transcript'; at: 'attachments' put: {
        Dictionary new at: 'id' put: 'voice-attachment'; at: 'kind' put: 'voice';
          at: 'transcript' put: 'fixture transcript'; yourself };
      yourself.
      entry replyEnvelope: (entry answer: message) for: 'voice-id'`, 'weixin-voice-one-call');
    assert.deepEqual(await weixinVoice(), {ok: true, value: {
      id: 'voice-id', text: 'fixture transcript voice reply', attachments: [],
      correctedTranscripts: [{id: 'voice-attachment', text: 'corrected fixture transcript'}],
    }});
    assert.equal(await gt(weixinCallCount, 'weixin-after-voice'), beforeVoice + 1);
    const objectCall = await submitModel("(LoomSessions session: 'isolation-check') fixtureCall: '活对象'", 'object-call');
    assert.deepEqual(await objectCall(), {ok: true, value: {session: 'isolation-check', argument: '活对象'}});
    const bound = await gt("LoomSessions show: 'isolation-check'", 'durable-binding');
    thread = bound.threadId;
    assert.match(thread, /^fixture-/);
    assert.equal(bound.threads.length, 1);
    const activity = await gt(`| page |
     page := (LoomNativeCodexHost instVarNamed: #registry)
      activitySummariesBefore: nil limit: 30 session: 'isolation-check' managedOnly: true.
     (page at: 'items') collect: [ :item | { item at: 'type'. item at: 'phase'. item at: 'text' } ]
    `, 'direct-codex-activity');
    assert.deepEqual(activity, [
      ['agentMessage', 'commentary', 'Starting offline'],
      ['agentMessage', 'final_answer', 'Unpublished draft'],
      ['dynamicToolCall', null, ''],
      ['agentMessage', 'final_answer', 'object callback completed'],
    ]);
    const recovery = await submitModel(`| session original result receipt |
      session := LoomSessions session: 'recovery-fixture'.
      original := Object new.
      result := session fixtureRecovery: original.
      receipt := session lastResponse.
      { result == original. receipt at: 'threadId'. receipt at: 'id' }`, 'object-recovery');
    const recovered = await recovery();
    assert.equal(recovered.ok, true, JSON.stringify(recovered));
    const [sameObject, recoveryThread, recoveryId] = recovered.value;
    assert.equal(sameObject, true);
    const requestFor = id => read(path.join(ipc, 'codex-requests', id + '.json'));
    const recoveryRequests = await gt(`LoomNativeCodexHost registry database: [ :db |
      (db execute: 'SELECT request_id FROM calls WHERE json_extract(result_json, ''$.threadId'') = ?
        ORDER BY rowid' values: { '${recoveryThread}' }) asArray ]`, 'recovery-attempt-ids');
    assert.equal(recoveryRequests.length, 3);
    assert.equal(recoveryRequests[2], recoveryId);
    assert.ok(recoveryRequests.every(id => requestFor(id).prompt === 'Loom 调用了你。'));
    assert.deepEqual(recoveryRequests.map(id => requestFor(id).originalRequestId),
      [undefined, recoveryRequests[0], recoveryRequests[0]]);
    const recoveryReceipts = recoveryRequests.map(id => read(path.join(ipc, 'codex-responses', id + '.json')));
    assert.deepEqual(recoveryReceipts.map(receipt => [receipt.turnStatus, receipt.ok, receipt.needsRecovery]),
      [['failed', false, true], ['completed', false, true], ['completed', true, undefined]]);
    assert.equal(recoveryReceipts[0].turnError.codexErrorInfo, 'fixtureError');
    const partial = await submitModel(`| session result receipt |
      session := LoomSessions session: 'recovery-fixture'.
      result := session fixtureCommitted: nil.
      receipt := session lastResponse.
      { result isNil. receipt at: 'ok'. receipt at: 'turnStatus'. receipt at: 'partialFailure'.
        receipt at: 'error' }`, 'object-partial-failure');
    assert.deepEqual(await partial(), {ok: true, value: [true, true, 'failed', true, 'fixture failure']});
    const interruptedObject = await submitModel(
      "(LoomSessions session: 'recovery-fixture') fixtureInterrupted: true", 'interrupted-object');
    assert.deepEqual(await interruptedObject(), {ok: false, error: 'Codex turn interrupted'});
    const primeHandoff = await submitModel(
      "(LoomSessions session: 'handoff-fixture') fixtureCall: 'prime'", 'handoff-bind-old-session');
    assert.equal((await primeHandoff()).ok, true);
    const handoff = await submitModel(`| session original result |
      session := LoomSessions session: 'handoff-fixture'.
      original := Object new.
      result := session requireThread: session threadId during: [ session fixtureHandoff: original ].
      { result == original. session lastResponse at: 'id'. session threadId }`, 'handoff-original-call');
    async function waitForHandoff() {
      const deadline = Date.now() + 30000;
      for (;;) {
        const record = await gt(`| record current |
          record := LoomSessions show: 'handoff-fixture'.
          current := (LoomNativeCodexHost instVarNamed: #transport) active.
          (current notNil and: [ (current at: 'messages') values anySatisfy: [ :item |
           (item at: 'text' ifAbsent: [ nil ]) = 'Fixture ready for handoff' ] ])
            ifTrue: [ record ]`, 'wait-for-handoff');
        if (record?.call?.canHandoff) return record;
        if (Date.now() >= deadline) throw Error('The handoff fixture did not become ready');
        await sleep(100);
      }
    }
    const oldHandoff = await waitForHandoff();
    assert.match(await gt(`[ LoomSessions recover: 'handoff-fixture' request: 'stale' ]
      on: Error do: [ :error | error messageText ]`, 'reject-stale-handoff'), /当前轮次已变更/);
    const acceptedHandoff = await gt(
      `LoomSessions recover: 'handoff-fixture' request: '${oldHandoff.call.requestId}'`, 'request-handoff');
    assert.equal(acceptedHandoff.call.handoffRequested, true);
    assert.equal(acceptedHandoff.threadId, oldHandoff.threadId);
    assert.equal(acceptedHandoff.threads.length, 1);
    const releaseHandoff = path.join(fixture, 'workspace', 'release-fixture-handoff');
    fs.writeFileSync(releaseHandoff, '');
    const continuation = await handoff();
    fs.unlinkSync(releaseHandoff);
    assert.equal(continuation.ok, true, JSON.stringify(continuation));
    const [sameHandoffObject, replacementId, replacementThread] = continuation.value;
    assert.equal(sameHandoffObject, true);
    assert.notEqual(replacementThread, oldHandoff.threadId);
    const replacementRequest = requestFor(replacementId);
    assert.equal(replacementRequest.originalRequestId, oldHandoff.call.requestId);
    assert.equal(replacementRequest.replacesRequestId, oldHandoff.call.requestId);
    assert.equal(replacementRequest.prompt, 'Loom 调用了你。');
    const held = await submitModel(`| session result |
      session := LoomSessions session: 'handoff-fixture'.
      result := session fixtureHeldResult: nil.
      { result isNil. session lastResponse at: 'partialFailure'. session threadId }`, 'handoff-with-saved-result');
    const heldTurn = await waitForHandoff();
    await gt(`LoomSessions recover: 'handoff-fixture' request: '${heldTurn.call.requestId}'`, 'interrupt-saved-result');
    assert.deepEqual(await held(), {ok: true, value: [true, true, replacementThread]});
    const afterHandoff = await gt("LoomSessions show: 'handoff-fixture'", 'handoff-session-history');
    assert.deepEqual(afterHandoff.threads.map(entry => [entry.threadId, entry.current]),
      [[oldHandoff.threadId, false], [replacementThread, true]]);
    await submitModel("(LoomSessions session: 'isolation-check') ask: 'mock-active'", 'active-at-shutdown');
    const deadline = Date.now() + 90000;
    let running;
    while (!(running?.call?.turnId)) {
      if (Date.now() >= deadline) throw Error('The test turn did not start');
      running = await gt("LoomSessions show: 'isolation-check'", 'model-pending');
      await sleep(200);
    }
    assert.equal(running.runState, 'running');
    assert.equal(await gt('(LoomSessions class includesSelector: #stop:) not', 'no-session-stop-selector'), true);
    const stopError = await gt("[ LoomSessions command: 'stop' for: 'isolation-check' ] on: Error do: [ :error | error messageText ]",
      'obsolete-session-command');
    assert.match(stopError, /Unknown Loom session command/);
    const stillRunning = await gt("LoomSessions show: 'isolation-check'", 'model-still-running');
    assert.equal(stillRunning.call.requestId, running.call.requestId);
    assert.equal(fs.existsSync(path.join(ipc, 'codex-cancel')), false);
    uncertain = randomUUID();
    await gt(`(LoomNativeCodexHost instVarNamed: #registry) beginCall:
     (Dictionary new at: 'id' put: '${uncertain}'; at: 'action' put: 'ask';
      at: 'prompt' put: 'uncertain fixture'; at: 'clientKey' put: 'loom.isolation-check'; yourself).
      true`, 'uncertain-durable-call');
  }

  const migrationReceipt = path.join(fixture, 'state/sessions/codex-home-migrated.json');
  fs.writeFileSync(migrationReceipt, '{"threads":1}');
  fs.writeFileSync(path.join(ipc, 'stop.json'), '{}');
  await stoppedAfter(true);
  const sealed = new CheckpointStorage(fixture).verify();
  assert.equal(fs.readdirSync(path.join(fixture, 'state/runtime/checkpoints')).length, 1);
  assert.equal(path.resolve(read(sessionFile).image), sealed.image);
  fs.writeFileSync(path.join(fixture, 'main.changes'), '\n');
  // Reload the conversation source without changing the voice source.
  fs.appendFileSync(path.join(fixture, 'src/runtime/conversation.st'),
    ".\nLMConversation compile: 'restartFixtureMarker ^ true'.\n");
  await start(core.pid);
  assert.deepEqual(read(migrationReceipt), {threads: 1});
  assert.deepEqual(await gt('{ LoomIPC fullName. LMCodexClient package name asString }', 'restored-runtime-bindings'),
    [ipc, 'Loom-Codex']);
  await waitForApplication('conversation', 'ready');
  await waitForApplication('voice', 'ready');
  assert.equal(await gt('LMConversation includesSelector: #restartFixtureMarker', 'conversation-source-after-restart'), true);
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
  await gt(`| changes |
   changes := SourceFiles changesFileStream.
   changes close.
   changes closed ifFalse: [ self error: 'Fixture changes stream is still open' ].
   Smalltalk globals at: #LoomTestReload put: LoomApplications reload.
   true`, 'reload-after-restart-with-closed-changes');
  const markerDeadline = Date.now() + 30000;
  while (!(await gt('LMConversationStore includesSelector: #reloadFixtureMarker', 'reloaded-marker'))) {
    if (Date.now() >= markerDeadline) throw Error('Source changed on disk, but the restored GT did not compile it');
    await sleep(150);
  }
  await waitForApplication('conversation', 'ready');
  assert.equal(await gt('SourceFiles changesFileStream closed not', 'reopened-changes-stream'), true);
  assert.equal(fs.readFileSync(path.join(fixture, 'main.changes'), 'utf8'), '\n');
  if (mockCodex) {
    const interrupted = read(path.join(ipc, 'codex-responses', uncertain + '.json'));
    assert.equal(interrupted.ok, false);
    assert.match(interrupted.error, /uncertain outcome/);
    const resumed = await submitModel("(LoomSessions session: 'isolation-check') ask: '会话续接'", 'resumed-model-call');
    assert.deepEqual(await resumed(), {ok: true, value: '会话续接 回执'});
    assert.equal((await gt("LoomSessions show: 'isolation-check'", 'resumed-binding')).threadId, thread);
    const activityBeforeEcho = await gt(`| page |
     page := (Smalltalk globals at: #LoomNativeCodexHost) registry
      activitySummariesBefore: nil limit: 1 session: LoomSessions mainId managedOnly: false.
     (page at: 'items') ifEmpty: [ 0 ] ifNotEmpty: [ :items | items last at: 'seq' ]`,
    'activity-before-restored-echo');
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
    const resumedActivity = await gt(`| view reader |
     view := LoomTestEchoView.
     view applyUpdate: view collectUpdate.
     reader := (view instVarNamed: #bodyPane) userData at: #activityTimeline.
     { reader registry == (Smalltalk globals at: #LoomNativeCodexHost) registry.
      (view instVarNamed: #activityItems) anySatisfy: [ :item |
       (item at: 'seq') > ${activityBeforeEcho} and: [ (item at: 'type') = 'dynamicToolCall' ] ] }`,
    'live-activity-after-restored-echo');
    assert.deepEqual(resumedActivity, [true, true]);
    const [audioId, messageId] = await gt(`| manager job |
     manager := Smalltalk globals at: #LoomGtVoice.
     job := manager makeJob: 'Voice restart fixture' original: 'original.wav'.
     job at: 'state' put: 'processing'; at: 'nextPoll' put: 9999999999999.
     manager save: job.
     { job at: 'id'. LoomConversation submitAudio: (job at: 'id') text: '' }`,
    'submit-untranscribed-recording-after-restart');
    assert.equal(await gt('LoomConversation nextInput isNil', 'pending-audio-waits-for-transcription'), true);
    await gt(`| manager job |
     manager := Smalltalk globals at: #LoomGtVoice.
     job := manager job: '${audioId}'.
     job at: 'state' put: 'completed'; at: 'transcript' put: 'voice fixture'.
     manager save: job.
     LoomConversation start.
     true`, 'complete-fixture-transcription');
    const voiceDeadline = Date.now() + 30000;
    for (;;) {
      const result = await gt(`| record reply correction |
       record := LoomConversation records detect: [ :item | (item at: 'id') = '${messageId}' ].
       reply := record at: 'reply' ifAbsent: [ nil ].
       reply ifNotNil: [
        correction := LoomConversation speechCorrectionAt: '${messageId}'.
        { reply at: 'ok'. reply at: 'text'. correction ifNotNil: [
           { correction at: 'ok'. correction at: 'text'.
            (correction at: 'threadId') = ((reply at: 'invocation') at: 'threadId') } ] } ]`,
      'read-corrected-voice-reply');
      if (result) {
        assert.deepEqual(result, [true, 'voice fixture corrected reply', [true, 'voice fixture corrected', true]]);
        break;
      }
      if (Date.now() >= voiceDeadline) throw Error('The restored conversation did not correct and answer the recording');
      await sleep(200);
    }
    const closeStartedFile = path.join(fixture, 'browser-close-started.json');
    const closeReleaseFile = path.join(fixture, 'browser-close-release');
    for (const variant of ['none', 'keep', 'close', 'close-failed']) {
      const prompt = 'browser fixture ' + variant;
      const action = variant === 'close-failed' ? 'close' : variant;
      const id = await gt(`LoomConversation submit: '${prompt}'`, 'submit-browser-' + variant);
      let originalInvocation;
      if (action === 'close') {
        const started = await until('browser cleanup callback', () => read(closeStartedFile), 30000);
        assert.equal(started[0], 'main');
        originalInvocation = started[1];
        const beforePublish = await gt(`| payload last row staged request |
         payload := LoomTestEchoView collectUpdate.
         last := (payload at: 'messages') last.
         row := LMConversationMessageView new controller: LoomTestEchoView; descriptor: last; yourself.
         staged := LoomConversation storage: 'staged-browser-reply' options: (Dictionary new at: 'id' put: '${id}'; yourself).
         request := (LoomConversation instVarNamed: #client) activeRequestId.
         { last at: 'id'. last at: 'text'. (row instVarNamed: 'stateLabel') text asString. payload at: 'sendAllowed'.
           staged at: 'text'. (staged at: 'invocation') at: 'id'.
           ((Smalltalk globals at: #LoomNativeCodexHost) registry activityAnswerFor: request) includesSubstring: 'Unpublished draft' }`,
        'browser-cleanup-holds-reply');
        assert.deepEqual(beforePublish, [id + '-assistant', '', '正在处理…', false,
          prompt + ' reply', originalInvocation, true]);
        fs.writeFileSync(closeReleaseFile, '');
      }
      const deadline = Date.now() + 30000;
      for (;;) {
        const result = await gt(`| record reply presented |
         record := LoomConversation records detect: [ :item | (item at: 'id') = '${id}' ].
         reply := record at: 'reply' ifAbsent: [ nil ].
         reply ifNotNil: [
          presented := (LoomTestEchoView collectUpdate at: 'messages') last.
          { reply at: 'ok'. reply at: 'text'. reply at: 'browserAction'. reply at: 'browserClose' ifAbsent: [ nil ].
           (reply at: 'invocation') at: 'id'. presented at: 'status' ifAbsent: [ nil ].
           (LoomConversation storage: 'staged-browser-reply' options: (Dictionary new at: 'id' put: '${id}'; yourself)) isNil } ]`,
        'published-browser-' + variant);
        if (result) {
          const browserClose = variant === 'close' ? {ok: true} : variant === 'close-failed' ?
            {ok: false, error: 'fixture could not close browser'} : null;
          assert.deepEqual(result.slice(0, 4), [true, prompt + ' reply', action, browserClose]);
          if (originalInvocation) assert.equal(result[4], originalInvocation);
          assert.deepEqual(result.slice(5), [variant === 'close-failed' ? '浏览器关闭未确认' : null, true]);
          break;
        }
        if (Date.now() >= deadline) throw Error('The browser fixture reply was not published: ' + variant);
        await sleep(200);
      }
      if (action === 'close') {
        fs.unlinkSync(closeStartedFile);
        fs.unlinkSync(closeReleaseFile);
      } else assert.equal(fs.existsSync(closeStartedFile), false);
    }
    const orphanId = randomUUID();
    await gt(`(LoomConversation instVarNamed: #worker) terminate.
     LoomConversation instVarNamed: #worker put: nil.
     LoomConversation storage: 'submit' options: (Dictionary new at: 'id' put: '${orphanId}';
      at: 'text' put: 'browser fixture interrupted'; at: 'createdAt' put: DateAndTime now asString; yourself).
     LoomConversation storage: 'stage-browser-reply' options: (Dictionary new at: 'reply' put:
      (Dictionary new at: 'id' put: '${orphanId}'; at: 'ok' put: true; at: 'text' put: 'Preserved answer';
       at: 'browserAction' put: 'close'; yourself); yourself).
     LoomConversation start.
     true`, 'recover-browser-reply-without-old-worker');
    const orphanDeadline = Date.now() + 12000;
    for (;;) {
      const reply = await gt(`(LoomConversation records detect: [ :item | (item at: 'id') = '${orphanId}' ])
       at: 'reply' ifAbsent: [ nil ]`, 'recover-staged-browser-reply');
      if (reply) {
        assert.equal(reply.text, 'Preserved answer');
        assert.deepEqual(reply.browserClose, {ok: false, error: '关闭状态待确认'});
        assert.equal(fs.existsSync(closeStartedFile), false);
        break;
      }
      if (Date.now() >= orphanDeadline) throw Error('The saved answer was not recovered after interruption');
      await sleep(150);
    }
  }
  await gt('[ Smalltalk snapshot: false andQuit: true ] fork. true', 'discard-fixture-runtime');
  await stoppedAfter(false);
  console.log('GT hot reload, fault isolation, attachments, native audio and checkpoint restart passed.');
} catch (error) {
  for (const name of ['voice-test/test-progress.json', 'logs/supervisor.log', 'logs/codex.stderr.log',
    'logs/runtime.stderr.log', 'logs/runtime.stdout.log', 'PharoDebug.log']) {
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
