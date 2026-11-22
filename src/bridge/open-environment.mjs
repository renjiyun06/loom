import {fileURLToPath} from 'node:url';
import {openEnvironment as openDesktop} from '../runtime/open-desktop.mjs';

export function openEnvironment({restoreConversation = false} = {}) {
  return openDesktop({restoreApplications: restoreConversation});
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await openEnvironment())); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
