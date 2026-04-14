#!/usr/bin/env node
/**
 * PostToolUse hook — finishes the fork work after the parent CC has
 * written the fork tool_use entry to its JSONL.
 *
 * Reads the hook JSON payload from stdin:
 *   { session_id: <parent CC UUID>, tool_name, tool_input, tool_response }
 *
 * If `tool_name` indicates a fork call and there is a matching
 * pending-fork record at ~/.loom/pending-forks/<session_id>.json,
 * runs executeFork(). Otherwise does nothing.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync, unlinkSync } from "node:fs";
import { dirname } from "node:path";

import { executeFork, type ForkJob } from "../fork-impl.js";
import { LOOM_DEBUG_LOG, LOOM_HOME, pendingForkPath } from "../utils.js";

function log(line: string) {
  mkdirSync(LOOM_HOME, { recursive: true });
  appendFileSync(
    LOOM_DEBUG_LOG,
    `[${new Date().toISOString()}] post-fork: ${line}\n`,
  );
}

async function readStdin(): Promise<string> {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf-8");
    process.stdin.on("data", (chunk) => (data += chunk));
    process.stdin.on("end", () => resolve(data));
  });
}

function isForkToolCall(name: string | undefined): boolean {
  if (!name) return false;
  // MCP tool names can appear as `fork` or `mcp__loom__fork`; accept both.
  return name === "fork" || /(^|_)fork$/.test(name);
}

async function main() {
  let payload: any;
  try {
    const raw = await readStdin();
    payload = JSON.parse(raw);
  } catch (err) {
    log(`failed to parse stdin: ${err}`);
    return; // don't block CC
  }

  const toolName: string | undefined = payload?.tool_name;
  const parentCcSessionId: string | undefined = payload?.session_id;
  const toolUseId: string | undefined = payload?.tool_use_id;

  if (!isForkToolCall(toolName)) {
    // Not our tool; silent no-op.
    return;
  }

  if (!parentCcSessionId) {
    log(`fork hook fired without session_id; payload=${JSON.stringify(payload)}`);
    return;
  }

  if (!toolUseId) {
    log(`fork hook fired without tool_use_id; payload keys=${Object.keys(payload ?? {}).join(",")}`);
    return;
  }

  const pendingPath = pendingForkPath(parentCcSessionId);
  if (!existsSync(pendingPath)) {
    log(
      `fork hook fired but no pending-fork file at ${pendingPath}; ` +
        `this fork may have been processed already or the MCP handler failed.`,
    );
    return;
  }

  let job: ForkJob;
  try {
    job = JSON.parse(readFileSync(pendingPath, "utf-8")) as ForkJob;
  } catch (err) {
    log(`failed to read pending-fork file ${pendingPath}: ${err}`);
    return;
  }

  log(
    `executing fork: parent=${job.parentBranchId} child=${job.childBranchId} ` +
      `inherit=${job.inheritContext} tool_use_id=${toolUseId}`,
  );

  try {
    await executeFork(job, toolUseId);
    unlinkSync(pendingPath);
    log(`fork completed: child=${job.childBranchId}`);
  } catch (err) {
    log(`executeFork failed for child=${job.childBranchId}: ${err}`);
    // Leave the pending file in place for debugging.
  }
}

main().catch((err) => {
  log(`unhandled error: ${err}`);
});
