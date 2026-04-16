/**
 * `loom relaunch <session> [branch]` — ensure a branch's tmux session
 * is alive without attaching. Intended for tooling (e.g. agentboard's
 * loom tree view) that wants to wake dead branches without attaching.
 *
 * Exit codes:
 *   0  — tmux session is now alive (either already was, or freshly launched)
 *   1  — error (branch not registered, agent binary missing, etc.)
 */

import {
  BranchNotRegisteredError,
  SessionNotRegisteredError,
  NotBuiltError,
  AgentBinaryMissingError,
  ensureBranchAlive,
} from "../core/ensure-branch-alive.js";
import { requireTools } from "./preflight.js";

export function cmdRelaunch(loomSessionId: string, branch = "main"): void {
  requireTools(["tmux"]);

  let result;
  try {
    result = ensureBranchAlive(loomSessionId, branch);
  } catch (err) {
    if (
      err instanceof BranchNotRegisteredError ||
      err instanceof SessionNotRegisteredError ||
      err instanceof NotBuiltError ||
      err instanceof AgentBinaryMissingError
    ) {
      console.error(`loom: ${err.message}`);
      process.exit(1);
    }
    throw err;
  }

  // One line of machine-parseable output; stderr stays for humans.
  console.log(`${result.status}: ${result.tmuxName}`);
  process.exit(0);
}
