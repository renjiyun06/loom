/**
 * `loom new [--agent <type>]` — start a new session on a fresh main branch.
 *
 * Flow:
 *   1. Snapshot existing session files (for discover step)
 *   2. Launch agent detached in tmux (agent may or may not honor our
 *      pre-allocated UUID)
 *   3. Ask the adapter to discover the real session id (CC returns
 *      hintId instantly; Codex polls until it sees a new rollout)
 *   4. If discovered id differs from our hint, update the DB row
 *   5. tmux attach the user into the live session
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
  NEW_SESSION_LOCK,
} from "../core/paths.js";
import { renderSystemPrompt } from "../core/system-prompt.js";
import { tmuxSessionName, sessionExists, newSession } from "../core/tmux.js";
import { nowMs, randomHex, withFileLock } from "../core/utils.js";
import { writeLaunchScript } from "../core/launch-script.js";
import { requireBuilt, requireTools, requireAgentBinary } from "./preflight.js";

export interface NewOpts {
  agent: AgentType;
}

export async function cmdNew(opts: NewOpts): Promise<void> {
  requireBuilt();
  requireTools(["tmux", "sqlite3"]);
  requireAgentBinary(opts.agent);

  const adapter = getAdapter(opts.agent);
  adapter.ensureGlobalConfig({ mcpServerPath: MCP_SERVER_PATH });

  const loomSessionId = randomHex(4);
  const agentSessionIdHint = adapter.generateSessionId();
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
      agent_session_id: agentSessionIdHint,
      parent_branch_id: null,
      instruction: null,
      inherit_context: null,
      created_at: nowMs(),
    });
  })();

  const promptText = renderSystemPrompt({ branchId: "main" });
  const argv = adapter.buildLaunchCommand({
    agentSessionId: agentSessionIdHint,
    cwd,
    loomSessionId,
    branchId: "main",
    systemPromptText: promptText,
    resume: false,
  });
  const launchScript = writeLaunchScript({
    loomSessionId,
    branchId: "main",
    argv,
  });

  console.error(
    `loom: session=${loomSessionId}  branch=main  agent=${opts.agent}  ` +
      `agent_session=${agentSessionIdHint}`,
  );
  console.error(`loom: tmux session ${tmuxName}`);

  // Serialize the snapshot → launch → discover window across concurrent
  // `loom new` invocations so two simultaneous agent launches cannot
  // confuse each other's new session files.
  let realId = agentSessionIdHint;
  try {
    realId = await withFileLock(
      NEW_SESSION_LOCK,
      async () => {
        const beforeFiles = adapter.listExistingSessionFiles(cwd);
        newSession({
          name: tmuxName,
          cwd,
          command: launchScript,
          detached: true,
          env: { LOOM_SESSION: loomSessionId, LOOM_BRANCH: "main" },
        });
        return adapter.discoverNewSessionId({
          cwd,
          hintId: agentSessionIdHint,
          beforeFiles,
        });
      },
      { timeoutMs: 60_000 },
    );
  } catch (err) {
    console.error(`loom: failed to discover agent session id: ${err}`);
    console.error(`loom: leaving tmux session alive; attach manually to debug`);
    process.exit(1);
  }

  if (realId !== agentSessionIdHint) {
    db.prepare(
      `UPDATE branches SET agent_session_id = ? WHERE session_id = ? AND branch_id = ?`,
    ).run(realId, loomSessionId, "main");
    console.error(
      `loom: agent chose its own session id (${realId}); DB updated`,
    );
  }

  console.error(
    `loom: detach with Ctrl-B d; reattach with 'loom attach ${loomSessionId}'`,
  );

  // Hand control back to the user by attaching to the live tmux session.
  const res = spawnSync("tmux", ["attach", "-t", tmuxName], {
    stdio: "inherit",
  });
  if (res.status !== null) process.exit(res.status);
  process.exit(1);
}
