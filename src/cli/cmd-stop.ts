/**
 * `loom stop <session> [branch] [--only]` — kill tmux session(s) without
 * touching DB rows. `loom attach` can relaunch.
 *
 * Behavior:
 *   - no branch: kill every live branch of the session.
 *   - branch (default): kill the branch AND all its descendants (post-order:
 *     leaves first, root last).
 *   - branch --only: kill just that one branch's tmux session.
 */

import { listDescendantBranchIds, openDb } from "../core/db.js";
import { killSession, listLoomSessions, tmuxSessionName } from "../core/tmux.js";
import { requireTools } from "./preflight.js";

export interface StopOpts {
  only?: boolean;
}

export function cmdStop(
  loomSessionId: string,
  branch: string | undefined,
  opts: StopOpts = {},
): void {
  requireTools(["tmux"]);

  if (!branch) {
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
    return;
  }

  if (opts.only) {
    const name = tmuxSessionName(loomSessionId, branch);
    killSession(name);
    console.log(`loom: killed ${name}`);
    return;
  }

  // Subtree: descendants first (post-order), root last.
  const db = openDb();
  const ids = listDescendantBranchIds(db, loomSessionId, branch);
  if (!ids.length) {
    console.error(
      `loom: branch ${branch} not found in session ${loomSessionId}`,
    );
    process.exit(1);
  }
  const ordered = [...ids].reverse();
  for (const bid of ordered) {
    const name = tmuxSessionName(loomSessionId, bid);
    killSession(name);
    console.log(`loom: killed ${name}`);
  }
}
