import fs from 'node:fs';
import path from 'node:path';
import {fork} from 'node:child_process';
import {root, paths, childEnvironment} from '../bridge/paths.mjs';
import {atomicJSON} from '../bridge/atomic-files.mjs';

export function launchApplications({runtimeSession, gui}) {
  const statusFile = path.join(paths.ipc, 'application-status.json');
  const reloadFile = path.join(paths.ipc, 'application-reload.json');
  let shuttingDown = false, reloading;
  let current = startApplicationProcess();

  return {
    poll() {
      if (shuttingDown || reloading || !fs.existsSync(reloadFile)) return;
      let request;
      try {
        const content = fs.readFileSync(reloadFile, 'utf8');
        fs.unlinkSync(reloadFile);
        request = JSON.parse(content);
      } catch (error) {
        if (error.code !== 'ENOENT') console.error('Application reload request:', error.message);
        return;
      }
      if (request?.session !== runtimeSession) return;
      reloading = (async () => {
        await current?.stop();
        if (!shuttingDown) current = startApplicationProcess();
      })().catch(error => console.error('Application reload:', error.message))
        .finally(() => { reloading = undefined; });
    },
    async prepareShutdown() {
      shuttingDown = true;
      await reloading;
      await current?.prepareShutdown();
    },
    async stop() {
      shuttingDown = true;
      await reloading;
      await current?.stop();
    }
  };

  function startApplicationProcess() {
    try { atomicJSON(statusFile, {session: runtimeSession, phase: 'starting'}); }
    catch (error) { console.error('Application status:', error.message); }
    return forkApplication({runtimeSession, gui, statusFile});
  }
}

function forkApplication({runtimeSession, gui, statusFile}) {
  const reportFailure = error => {
    console.error('Application host:', error.message);
    try {
      atomicJSON(statusFile, {session: runtimeSession, phase: 'failed', error: error.message});
    } catch (statusError) {
      console.error('Application status:', statusError.message);
    }
  };

  let child;
  try {
    child = fork(path.join(root, 'src/runtime/serve-applications.mjs'), [runtimeSession, gui ? 'gui' : 'headless'],
      {cwd: root, env: childEnvironment, windowsHide: true, stdio: ['ignore', 'inherit', 'inherit', 'ipc']});
  } catch (error) {
    reportFailure(error);
    return;
  }

  let stopping = false;
  let terminated = false;
  child.on('error', error => {
    if (!stopping) reportFailure(error);
  });
  const closed = new Promise(resolve => child.once('close', (code, signal) => {
    terminated = true;
    if (!stopping) reportFailure(Error(`Application process exited (${signal ?? code})`));
    resolve();
  }));

  const send = message => child.send(message, error => {
    if (error) console.error('Application shutdown:', error.message);
  });
  return {
    async prepareShutdown() {
      if (!child.connected || terminated) return;
      let deadline, receive;
      const prepared = new Promise(resolve => {
        receive = message => { if (message === 'prepared') resolve(); };
        child.on('message', receive);
      });
      send('prepare');
      try {
        await Promise.race([closed, prepared, new Promise(resolve => { deadline = setTimeout(resolve, 8000); })]);
      } finally {
        clearTimeout(deadline);
        child.off('message', receive);
      }
    },
    async stop() {
      stopping = true;
      if (terminated) return;
      if (!child.connected) { child.kill(); await closed; return; }
      send('stop');
      let deadline;
      try {
        await Promise.race([closed, new Promise(resolve => {
          deadline = setTimeout(resolve, 10000);
        })]);
      } finally {
        clearTimeout(deadline);
      }
      if (!terminated) { child.kill(); await closed; }
    }
  };
}
