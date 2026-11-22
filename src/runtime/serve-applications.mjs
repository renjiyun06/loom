import path from 'node:path';
import {root, paths} from '../bridge/paths.mjs';
import {atomicJSON} from '../bridge/atomic-files.mjs';
import {evaluate} from '../bridge/runtime-client.mjs';
import {VoiceService} from '../audio/voice-service.mjs';
import {ConversationStore} from '../conversation/store.mjs';
import {ConversationService} from '../conversation/service.mjs';
import {openEnvironment} from './open-desktop.mjs';

const [session, mode] = process.argv.slice(2);
const gui = mode === 'gui';
const statusFile = path.join(paths.ipc, 'application-status.json');
const state = {session, pid: process.pid, phase: 'starting',
  conversation: {phase: 'starting'}, voice: {phase: 'starting'}};
let store, conversation, voice, conversationTimer, voiceTimer, voiceShutdown, closing = false, stopping = false;

function publish() {
  try {
    atomicJSON(statusFile, state);
  } catch (error) {
    console.error('Application status:', error.message);
  }
}

function failure(name, error) {
  console.error(`${name}:`, error.message);
  state[name] = {phase: 'failed', error: error.message};
  publish();
}

function conversationFailed(error) {
  clearInterval(conversationTimer);
  failure('conversation', error);
}

function voiceFailed(error) {
  clearInterval(voiceTimer);
  failure('voice', error);
}

async function runInGT(code, label) {
  const response = await evaluate(code, label);
  if (!response.ok) throw Error(response.message ?? response.error ?? 'GT application request failed');
  return response.value;
}

async function start() {
  publish();
  try {
    store = new ConversationStore(path.join(root, 'state/conversation'));
    conversation = new ConversationService(paths.ipc, store);
    conversationTimer = setInterval(() => {
      try { conversation.poll(conversationFailed); }
      catch (error) { conversationFailed(error); }
    }, 40);
  } catch (error) {
    conversationFailed(error);
  }

  try {
    const errors = await runInGT(
      "Smalltalk compiler evaluate: (ExperimentRoot / 'src' / 'runtime' / 'applications.st') contents",
      'install-applications');
    if (closing) return;
    for (const [name, message] of Object.entries(errors)) {
      if (name === 'conversation') conversationFailed(Error(message));
      else failure(name, Error(message));
    }
  } catch (error) {
    conversationFailed(error);
  }
  if (closing) return;

  if (state.conversation.phase === 'starting') {
    state.conversation = {phase: 'ready'};
    publish();
    try {
      await runInGT('LoomConversation start. true', 'start-conversation');
    } catch (error) {
      conversationFailed(error);
    }
  }
  if (closing) return;

  try {
    voice = new VoiceService(root, {
      audioMessages: () => store?.audioMessages() ?? [],
      notify: async () => {
        if (!closing && state.conversation.phase === 'ready')
          await runInGT('LoomConversation start. true', 'voice-ready');
      }
    });
    voiceTimer = setInterval(() => { void voice.poll().catch(voiceFailed); }, 200);
    state.voice = {phase: 'ready'};
  } catch (error) {
    voiceFailed(error);
  }

  if (gui) {
    try {
      await openEnvironment({restoreApplications: true});
      state.desktop = {phase: 'ready'};
    } catch (error) {
      failure('desktop', error);
    }
  }
  if (closing) return;
  state.phase = 'ready';
  publish();
}

async function stop() {
  if (stopping) return;
  stopping = true;
  state.phase = 'stopping';
  publish();
  clearInterval(conversationTimer);
  const closeConversation = async () => {
    if (conversation) await conversation.close();
    else store?.close();
  };
  const results = await Promise.allSettled([prepareShutdown(), closeConversation()]);
  for (const result of results) {
    if (result.status === 'rejected') console.error('Application shutdown:', result.reason);
  }
  process.exit(0);
}

function prepareShutdown() {
  closing = true;
  clearInterval(voiceTimer);
  voiceShutdown ??= Promise.resolve().then(() => voice?.close()).catch(error => {
    console.error('Voice shutdown:', error.message);
  });
  return voiceShutdown;
}

process.on('message', message => {
  if (message === 'stop') void stop();
  if (message === 'prepare') void prepareShutdown().then(() => {
    if (process.connected) process.send('prepared', () => {});
  });
});
process.on('disconnect', () => { void stop(); });
if (!session || !process.connected) throw Error('The Loom application host requires a runtime session and a supervisor channel');
await start();
