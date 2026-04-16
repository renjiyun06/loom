/**
 * Shared entry logic for CC PostToolUse and Codex Stop hooks.
 *
 * Each agent-specific hook script parses its own payload via the
 * adapter's parseHookPayload, checks for a pending-fork file, and if
 * present delegates to executeFork.
 */

import { appendFileSync, mkdirSync } from "node:fs";
import type { AgentAdapter } from "../adapters/types.js";
import { LOOM_HOME, LOOM_DEBUG_LOG } from "./paths.js";
import { consumePendingFork } from "./pending-fork.js";
import { executeFork } from "./execute-fork.js";

function readStdin(): Promise<string> {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf-8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolve(data));
  });
}

function log(line: string): void {
  try {
    mkdirSync(LOOM_HOME, { recursive: true });
    appendFileSync(
      LOOM_DEBUG_LOG,
      `[${new Date().toISOString()}] hook: ${line}\n`,
    );
  } catch {
    // best-effort
  }
}

export async function runHookFlow(adapter: AgentAdapter): Promise<void> {
  let raw: string;
  try {
    raw = await readStdin();
  } catch (err) {
    log(`readStdin failed: ${err}`);
    return;
  }

  const info = adapter.parseHookPayload(raw);
  if (!info.mayBeFork) return;
  if (!info.agentSessionId) {
    log(`hook fired without agent session id; agent=${adapter.agentType}`);
    return;
  }

  const job = consumePendingFork(info.agentSessionId);
  if (!job) return; // normal hook firing, not ours

  log(
    `executing fork: parent=${job.parentBranchId} child=${job.childBranchId} ` +
      `agent=${adapter.agentType} trigger=${info.triggerHint}`,
  );
  try {
    await executeFork({ job, triggerHint: info.triggerHint });
    log(`fork complete: child=${job.childBranchId}`);
  } catch (err) {
    log(`executeFork failed for child=${job.childBranchId}: ${err}`);
    throw err;
  }
}
