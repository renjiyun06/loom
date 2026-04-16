/**
 * Agent-neutral fork execution flow.
 *
 * Orchestrates: wait for parent's fork call to be flushed, synthesize
 * child session file, launch child agent in tmux, inject kickoff
 * message. Delegates all agent-specific work to adapters.
 */

import {
  MCP_SERVER_PATH,
  CC_POST_HOOK_PATH,
  CODEX_STOP_HOOK_PATH,
} from "./paths.js";
import { getAdapter } from "../adapters/factory.js";
import { getSession } from "./db.js";
import { openDb } from "./db.js";
import { renderSystemPrompt } from "./system-prompt.js";
import { newSession, sendKeys, tmuxSessionName } from "./tmux.js";
import { sendLockPath, sleep, withFileLock, shellQuote } from "./utils.js";
import type { ForkJob } from "../types.js";

/**
 * Resolve the hook script path an adapter's ensureGlobalConfig needs.
 * Callers of ensureGlobalConfig pass this explicitly; executeFork does
 * not need it directly (hooks.json is already installed).
 */
export function hookScriptPathFor(
  agentType: ForkJob["childAgentType"],
): string {
  return agentType === "claude-code" ? CC_POST_HOOK_PATH : CODEX_STOP_HOOK_PATH;
}

function renderBirthAnnouncement(
  parentBranchId: string,
  childBranchId: string,
  inheritContext: boolean,
): string {
  const suffix = inheritContext
    ? ""
    : " without context inheritance";
  return `You are branch ${childBranchId}, forked from branch ${parentBranchId}${suffix}.`;
}

export interface ExecuteForkParams {
  job: ForkJob;
  /** Agent-native trigger identifier from the hook payload. */
  triggerHint: string;
  /**
   * How long to wait for the kickoff message's target TUI to come up
   * before tmux send-keys. Defaults to 10s (CC) or 10s (Codex) — both
   * have similar startup characteristics.
   */
  kickoffDelayMs?: number;
}

export async function executeFork(params: ExecuteForkParams): Promise<void> {
  const { job, triggerHint } = params;
  const kickoffDelayMs = params.kickoffDelayMs ?? 10_000;

  const db = openDb();
  const sessionRow = getSession(db, job.loomSessionId);
  if (!sessionRow) {
    throw new Error(
      `executeFork: session ${job.loomSessionId} not registered`,
    );
  }
  const cwd = sessionRow.cwd;

  const parentAdapter = getAdapter(job.parentAgentType);
  const childAdapter = getAdapter(job.childAgentType);

  // 1. Wait for parent's fork call to be flushed to disk.
  const parentFile = parentAdapter.sessionFilePath(cwd, job.parentAgentSessionId);
  const forkLoc = await parentAdapter.waitForForkCall(parentFile, triggerHint);

  // 2. Build the child's session file content. (Cross-agent forks are
  //    not supported in MVP — this is only correct when parent and
  //    child share the same agent type.)
  if (job.parentAgentType !== job.childAgentType) {
    throw new Error(
      `cross-agent fork is not supported: parent=${job.parentAgentType}, child=${job.childAgentType}`,
    );
  }

  const childEntries = childAdapter.buildChildSessionEntries({
    forkLocation: forkLoc,
    childAgentSessionId: job.childAgentSessionId,
    parentBranchId: job.parentBranchId,
    childBranchId: job.childBranchId,
    inheritContext: job.inheritContext,
    instruction: job.instruction,
    cwd,
    birthAnnouncementText: renderBirthAnnouncement(
      job.parentBranchId,
      job.childBranchId,
      job.inheritContext,
    ),
  });

  // 3. Write the child's session file.
  const childPath = childAdapter.sessionFilePath(cwd, job.childAgentSessionId);
  childAdapter.writeEntries(childPath, childEntries);

  // 4. Launch the child agent in its own tmux session.
  const tmuxName = tmuxSessionName(job.loomSessionId, job.childBranchId);
  const promptText = renderSystemPrompt({ branchId: job.childBranchId });
  const argv = childAdapter.buildLaunchCommand({
    agentSessionId: job.childAgentSessionId,
    cwd,
    loomSessionId: job.loomSessionId,
    branchId: job.childBranchId,
    systemPromptText: promptText,
    resume: true,
  });
  newSession({
    name: tmuxName,
    cwd,
    command: argv.map(shellQuote).join(" "),
    env: {
      LOOM_SESSION: job.loomSessionId,
      LOOM_BRANCH: job.childBranchId,
    },
  });

  // 5. Wait for the TUI to come up, then inject the kickoff line.
  await sleep(kickoffDelayMs);
  await withFileLock(sendLockPath(tmuxName), () => {
    sendKeys(tmuxName, "[loom] Begin.");
  });
}

export { MCP_SERVER_PATH };
