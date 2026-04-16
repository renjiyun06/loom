/**
 * Read/write the per-session "pending fork" JSON file. The MCP fork
 * handler writes it immediately; the post-hook picks it up and executes
 * the real fork work.
 */

import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { pendingForkPath, ensurePendingForksDir } from "./utils.js";
import type { ForkJob } from "../types.js";

export function writePendingFork(
  parentAgentSessionId: string,
  job: ForkJob,
): void {
  ensurePendingForksDir();
  writeFileSync(pendingForkPath(parentAgentSessionId), JSON.stringify(job, null, 2));
}

export function readPendingFork(
  parentAgentSessionId: string,
): ForkJob | null {
  const path = pendingForkPath(parentAgentSessionId);
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as ForkJob;
  } catch {
    return null;
  }
}

export function consumePendingFork(
  parentAgentSessionId: string,
): ForkJob | null {
  const job = readPendingFork(parentAgentSessionId);
  if (job) {
    try {
      unlinkSync(pendingForkPath(parentAgentSessionId));
    } catch {
      // ignore
    }
  }
  return job;
}

export function deletePendingFork(parentAgentSessionId: string): void {
  try {
    unlinkSync(pendingForkPath(parentAgentSessionId));
  } catch {
    // ignore
  }
}
