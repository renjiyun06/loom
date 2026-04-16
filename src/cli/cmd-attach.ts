/**
 * `loom attach <session> [branch]` — attach to a branch's tmux session,
 * relaunching the agent if the tmux session isn't alive.
 */

import { spawnSync } from "node:child_process";
import {
  AgentBinaryMissingError,
  BranchNotRegisteredError,
  NotBuiltError,
  SessionNotRegisteredError,
  ensureBranchAlive,
} from "../core/ensure-branch-alive.js";
import { sleep } from "../core/utils.js";
import { requireTools } from "./preflight.js";

export async function cmdAttach(loomSessionId: string, branch = "main"): Promise<void> {
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

  if (result.status === "launched") {
    console.error(`loom: relaunching ${result.tmuxName} (agent=${result.agentType})`);
    // Detached launch + short wait + foreground attach, matching
    // `loom new`'s flow. Attaching the user's terminal directly to a
    // fresh pty while bash is still handing off to the agent causes
    // the terminal's DA1/DA2 capability-query response bytes to leak
    // into the agent's TUI as visible garbage. Waiting ~2s lets the
    // agent settle first.
    await sleep(2_000);
  }

  const res = spawnSync("tmux", ["attach", "-t", result.tmuxName], {
    stdio: "inherit",
  });
  process.exit(res.status ?? 1);
}
