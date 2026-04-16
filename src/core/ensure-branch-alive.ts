/**
 * Shared helper: make sure a registered branch's tmux session is alive.
 * If the tmux session already exists, returns 'already-alive' untouched.
 * Otherwise synthesizes the launch command from the adapter, starts a
 * detached tmux session, and returns 'launched'. Does not attach —
 * callers (loom attach / loom relaunch) attach separately if desired.
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import type { AgentType } from "../types.js";
import { getAdapter } from "../adapters/factory.js";
import { getBranch, getSession, openDb } from "./db.js";
import { writeLaunchScript } from "./launch-script.js";
import { MCP_SERVER_PATH } from "./paths.js";
import { renderSystemPrompt } from "./system-prompt.js";
import { newSession, sessionExists, tmuxSessionName } from "./tmux.js";

export type EnsureBranchAliveStatus = "already-alive" | "launched";

export interface EnsureBranchAliveResult {
  status: EnsureBranchAliveStatus;
  tmuxName: string;
  agentType: string;
}

export class BranchNotRegisteredError extends Error {}
export class SessionNotRegisteredError extends Error {}
export class NotBuiltError extends Error {}
export class AgentBinaryMissingError extends Error {}

function hasCommand(cmd: string): boolean {
  return spawnSync("which", [cmd], { stdio: "ignore" }).status === 0;
}

function agentBinaryName(agent: AgentType): string {
  return agent === "claude-code" ? "claude" : "codex";
}

/**
 * Ensures the tmux session for (loomSessionId, branchId) is alive.
 *
 * Callers are responsible for confirming that the `tmux` binary itself
 * is present (required even to probe session existence). This helper
 * throws typed errors for every other failure mode so the caller can
 * decide how to report / exit.
 */
export function ensureBranchAlive(
  loomSessionId: string,
  branchId: string,
): EnsureBranchAliveResult {
  const tmuxName = tmuxSessionName(loomSessionId, branchId);

  if (sessionExists(tmuxName)) {
    const db = openDb();
    const b = getBranch(db, loomSessionId, branchId);
    return {
      status: "already-alive",
      tmuxName,
      agentType: b?.agent_type ?? "unknown",
    };
  }

  const db = openDb();
  const b = getBranch(db, loomSessionId, branchId);
  if (!b) {
    throw new BranchNotRegisteredError(
      `branch ${branchId} in session ${loomSessionId} is not registered`,
    );
  }
  const sess = getSession(db, loomSessionId);
  if (!sess) {
    throw new SessionNotRegisteredError(
      `session ${loomSessionId} is not registered`,
    );
  }

  if (!existsSync(MCP_SERVER_PATH)) {
    throw new NotBuiltError(
      "loom MCP server not built; run `npm install && npm run build` first",
    );
  }

  const binary = agentBinaryName(b.agent_type);
  if (!hasCommand(binary)) {
    throw new AgentBinaryMissingError(
      `agent '${b.agent_type}' requires the \`${binary}\` binary in PATH`,
    );
  }

  const adapter = getAdapter(b.agent_type);
  adapter.ensureGlobalConfig({ mcpServerPath: MCP_SERVER_PATH });

  const promptText = renderSystemPrompt({ branchId });
  const argv = adapter.buildLaunchCommand({
    agentSessionId: b.agent_session_id,
    cwd: sess.cwd,
    loomSessionId,
    branchId,
    systemPromptText: promptText,
    resume: true,
  });
  const launchScript = writeLaunchScript({
    loomSessionId,
    branchId,
    argv,
  });

  newSession({
    name: tmuxName,
    cwd: sess.cwd,
    command: launchScript,
    detached: true,
    env: { LOOM_SESSION: loomSessionId, LOOM_BRANCH: branchId },
  });

  return {
    status: "launched",
    tmuxName,
    agentType: b.agent_type,
  };
}
