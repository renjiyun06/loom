/**
 * `loom stop <session> [branch]` — kill tmux session(s) without
 * touching DB rows. `loom attach` can relaunch.
 */

import { killSession, listLoomSessions, tmuxSessionName } from "../core/tmux.js";
import { requireTools } from "./preflight.js";

export function cmdStop(loomSessionId: string, branch?: string): void {
  requireTools(["tmux"]);
  if (branch) {
    const name = tmuxSessionName(loomSessionId, branch);
    killSession(name);
    console.log(`loom: killed ${name}`);
    return;
  }
  const prefix = `loom-${loomSessionId}-`;
  const names = listLoomSessions().filter((n) => n.startsWith(prefix));
  if (!names.length) {
    console.error(`loom: no live tmux sessions for ${loomSessionId}`);
    process.exit(1);
  }
  for (const n of names) {
    killSession(n);
    console.log(`loom: killed ${n}`);
  }
}
