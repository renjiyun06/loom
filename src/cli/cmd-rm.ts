/**
 * `loom rm <session> [branch] [-f]` — permanently remove a session or
 * branch subtree from Loom's records.
 *
 * What gets removed:
 *   - tmux sessions of affected branches (killed)
 *   - rows in the `branches` table (and `sessions` row if removing whole session)
 *   - pending-fork files for affected branches
 *
 * What is preserved:
 *   - Agent session files (CC JSONL under ~/.claude/projects, Codex
 *     rollouts under ~/.codex/sessions). Consistent with legacy loom.
 */

import { existsSync, readFileSync } from "node:fs";
import {
  deleteBranches,
  deleteSession,
  getBranch,
  getSession,
  listBranches,
  listDescendantBranchIds,
  openDb,
} from "../core/db.js";
import { killSession, tmuxSessionName } from "../core/tmux.js";
import { deletePendingFork } from "../core/pending-fork.js";
import { requireTools } from "./preflight.js";

export interface RmOpts {
  force: boolean;
}

function prompt(question: string): boolean {
  if (!process.stdin.isTTY) return false;
  process.stdout.write(question);
  try {
    const buf = Buffer.alloc(16);
    const n = readFileSync(0, { encoding: "utf-8" }).trim();
    return /^y(es)?$/i.test(n);
  } catch {
    return false;
  }
}

export function cmdRm(
  loomSessionId: string,
  branch: string | undefined,
  opts: RmOpts,
): void {
  requireTools(["tmux"]);
  const db = openDb();
  const sess = getSession(db, loomSessionId);
  if (!sess) {
    console.error(`loom: session ${loomSessionId} not found`);
    process.exit(1);
  }

  // Collect branch ids to delete.
  let toDelete: string[];
  let wholeSession = false;
  if (!branch || branch === "main") {
    wholeSession = true;
    toDelete = listBranches(db, loomSessionId).map((b) => b.branch_id);
  } else {
    const b = getBranch(db, loomSessionId, branch);
    if (!b) {
      console.error(`loom: branch ${branch} not found in ${loomSessionId}`);
      process.exit(1);
    }
    toDelete = listDescendantBranchIds(db, loomSessionId, branch);
  }

  if (!opts.force) {
    const summary = wholeSession
      ? `entire session ${loomSessionId} (${toDelete.length} branch(es))`
      : `branch ${branch} and ${toDelete.length - 1} descendant(s)`;
    if (!prompt(`Remove ${summary}? [y/N] `)) {
      console.error(`loom: aborted`);
      process.exit(1);
    }
  }

  for (const bid of toDelete) {
    const row = getBranch(db, loomSessionId, bid);
    if (row) deletePendingFork(row.agent_session_id);
    killSession(tmuxSessionName(loomSessionId, bid));
  }

  if (wholeSession) {
    deleteSession(db, loomSessionId);
    console.log(`loom: removed session ${loomSessionId}`);
  } else {
    deleteBranches(db, loomSessionId, toDelete);
    console.log(
      `loom: removed branch(es) ${toDelete.join(", ")} in session ${loomSessionId}`,
    );
  }
}
