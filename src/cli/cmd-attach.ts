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
import {
  MCP_SERVER_PATH,
  CC_POST_HOOK_PATH,
  CODEX_STOP_HOOK_PATH,
} from "../core/paths.js";
import { renderSystemPrompt } from "../core/system-prompt.js";
import { sessionExists, tmuxSessionName } from "../core/tmux.js";
import { shellQuote } from "../core/utils.js";
import { requireAgentBinary, requireBuilt, requireTools } from "./preflight.js";

export function cmdAttach(loomSessionId: string, branch = "main"): void {
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
  adapter.ensureGlobalConfig({
    mcpServerPath: MCP_SERVER_PATH,
    hookScriptPath:
      b.agent_type === "claude-code" ? CC_POST_HOOK_PATH : CODEX_STOP_HOOK_PATH,
  });

  const promptText = renderSystemPrompt({ branchId: branch });
  const argv = adapter.buildLaunchCommand({
    agentSessionId: b.agent_session_id,
    cwd: sess.cwd,
    loomSessionId,
    branchId: branch,
    systemPromptText: promptText,
    resume: true,
  });
  const command = argv.map(shellQuote).join(" ");

  console.error(`loom: relaunching ${tmuxName} (agent=${b.agent_type})`);
  const res = spawnSync(
    "tmux",
    [
      "new-session",
      "-s",
      tmuxName,
      "-e",
      `LOOM_SESSION=${loomSessionId}`,
      "-e",
      `LOOM_BRANCH=${branch}`,
      "-c",
      sess.cwd,
      command,
    ],
    { stdio: "inherit" },
  );
  process.exit(res.status ?? 1);
}
