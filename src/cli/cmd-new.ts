/**
 * `loom new [--agent <type>]` — start a new session on a fresh main branch.
 */

import { spawnSync } from "node:child_process";
import type { AgentType } from "../types.js";
import { getAdapter } from "../adapters/factory.js";
import {
  insertBranch,
  insertSession,
  openDb,
} from "../core/db.js";
import {
  MCP_SERVER_PATH,
  CC_POST_HOOK_PATH,
  CODEX_STOP_HOOK_PATH,
} from "../core/paths.js";
import { renderSystemPrompt } from "../core/system-prompt.js";
import { tmuxSessionName, sessionExists } from "../core/tmux.js";
import { nowMs, randomHex, shellQuote } from "../core/utils.js";
import { requireBuilt, requireTools, requireAgentBinary } from "./preflight.js";

export interface NewOpts {
  agent: AgentType;
}

export function cmdNew(opts: NewOpts): void {
  requireBuilt();
  requireTools(["tmux", "sqlite3"]);
  requireAgentBinary(opts.agent);

  const adapter = getAdapter(opts.agent);
  adapter.ensureGlobalConfig({
    mcpServerPath: MCP_SERVER_PATH,
    hookScriptPath:
      opts.agent === "claude-code" ? CC_POST_HOOK_PATH : CODEX_STOP_HOOK_PATH,
  });

  const loomSessionId = randomHex(4);
  const agentSessionId = adapter.generateSessionId();
  const cwd = process.cwd();
  const tmuxName = tmuxSessionName(loomSessionId, "main");

  if (sessionExists(tmuxName)) {
    console.error(`loom: tmux session ${tmuxName} already exists — aborting`);
    process.exit(1);
  }

  const db = openDb();
  db.transaction(() => {
    insertSession(db, { id: loomSessionId, cwd, created_at: nowMs() });
    insertBranch(db, {
      session_id: loomSessionId,
      branch_id: "main",
      agent_type: opts.agent,
      agent_session_id: agentSessionId,
      parent_branch_id: null,
      instruction: null,
      inherit_context: null,
      created_at: nowMs(),
    });
  })();

  const promptText = renderSystemPrompt({ branchId: "main" });
  const argv = adapter.buildLaunchCommand({
    agentSessionId,
    cwd,
    loomSessionId,
    branchId: "main",
    systemPromptText: promptText,
    resume: false,
  });

  const command = argv.map(shellQuote).join(" ");

  console.error(
    `loom: session=${loomSessionId}  branch=main  agent=${opts.agent}  ` +
      `agent_session=${agentSessionId}`,
  );
  console.error(`loom: tmux session ${tmuxName}`);
  console.error(
    `loom: detach with Ctrl-B d; reattach with 'loom attach ${loomSessionId}'`,
  );

  const envArgs: string[] = [];
  envArgs.push("-e", `LOOM_SESSION=${loomSessionId}`);
  envArgs.push("-e", `LOOM_BRANCH=main`);

  // exec replaces this node process — use tmux new-session in attached mode.
  const res = spawnSync(
    "tmux",
    [
      "new-session",
      "-s",
      tmuxName,
      "-c",
      cwd,
      ...envArgs,
      command,
    ],
    { stdio: "inherit" },
  );
  if (res.status !== null) process.exit(res.status);
  process.exit(1);
}
