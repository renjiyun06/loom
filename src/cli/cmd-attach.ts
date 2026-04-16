/**
 * `loom attach <session> [branch]` — attach to a branch's tmux session,
 * relaunching the agent if the tmux session isn't alive.
 */

import { spawnSync } from "node:child_process";
import { getAdapter } from "../adapters/factory.js";
import {
  getBranch,
  getSession,
  openDb,
} from "../core/db.js";
import { MCP_SERVER_PATH } from "../core/paths.js";
import { renderSystemPrompt } from "../core/system-prompt.js";
import { newSession, sessionExists, tmuxSessionName } from "../core/tmux.js";
import { writeLaunchScript } from "../core/launch-script.js";
import { sleep } from "../core/utils.js";
import { requireAgentBinary, requireBuilt, requireTools } from "./preflight.js";

export async function cmdAttach(loomSessionId: string, branch = "main"): Promise<void> {
  requireTools(["tmux"]);
  const tmuxName = tmuxSessionName(loomSessionId, branch);

  if (sessionExists(tmuxName)) {
    const res = spawnSync("tmux", ["attach", "-t", tmuxName], { stdio: "inherit" });
    process.exit(res.status ?? 1);
  }

  const db = openDb();
  const b = getBranch(db, loomSessionId, branch);
  if (!b) {
    console.error(`loom: branch ${branch} in session ${loomSessionId} is not registered`);
    process.exit(1);
  }
  const sess = getSession(db, loomSessionId);
  if (!sess) {
    console.error(`loom: session ${loomSessionId} is not registered`);
    process.exit(1);
  }

  requireBuilt();
  requireAgentBinary(b.agent_type);

  const adapter = getAdapter(b.agent_type);
  adapter.ensureGlobalConfig({ mcpServerPath: MCP_SERVER_PATH });

  const promptText = renderSystemPrompt({ branchId: branch });
  const argv = adapter.buildLaunchCommand({
    agentSessionId: b.agent_session_id,
    cwd: sess.cwd,
    loomSessionId,
    branchId: branch,
    systemPromptText: promptText,
    resume: true,
  });
  const launchScript = writeLaunchScript({
    loomSessionId,
    branchId: branch,
    argv,
  });

  console.error(`loom: relaunching ${tmuxName} (agent=${b.agent_type})`);

  // Detached launch + short wait + foreground attach, same flow as
  // `loom new`. Attaching the user's terminal directly to a fresh pty
  // while bash is still handing off to the agent causes the terminal's
  // DA1/DA2 capability-query response bytes to leak into the agent's
  // TUI as visible garbage. Waiting ~2s lets the agent settle first.
  newSession({
    name: tmuxName,
    cwd: sess.cwd,
    command: launchScript,
    detached: true,
    env: { LOOM_SESSION: loomSessionId, LOOM_BRANCH: branch },
  });
  await sleep(2_000);

  const res = spawnSync("tmux", ["attach", "-t", tmuxName], {
    stdio: "inherit",
  });
  process.exit(res.status ?? 1);
}
