import {paths} from './paths.mjs';
import {sessionCommand} from './session-control.mjs';

const [action,id,requestId]=process.argv.slice(2);
try {
  if(!['list','show','register','rotate','recover'].includes(action)||(action!=='list'&&!id)||(action==='recover'&&!requestId)) {
    throw new Error('Usage: manage-sessions.mjs list | show/register/rotate <session-id> | recover <session-id> <request-id>');
  }
  console.log(JSON.stringify(await sessionCommand(paths.ipc,action,id,requestId),null,2));
} catch(error) {
  console.error(error.message);
  process.exitCode=1;
}
