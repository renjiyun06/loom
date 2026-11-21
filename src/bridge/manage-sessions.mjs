import {paths} from './paths.mjs';
import {sessionCommand} from './session-control.mjs';

const [action,id]=process.argv.slice(2);
try {
  if(!['list','show','register','rotate','stop'].includes(action)||(action!=='list'&&!id)) {
    throw new Error('Usage: manage-sessions.mjs list | show/register/rotate/stop <session-id>');
  }
  console.log(JSON.stringify(await sessionCommand(paths.ipc,action,id),null,2));
} catch(error) {
  console.error(error.message);
  process.exitCode=1;
}
