/**
 * Codex launch command builder and global-config writer.
 */

import { spawnSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  EnsureGlobalConfigOpts,
  LaunchCommandOpts,
} from "../types.js";
import { CODEX_STOP_HOOK_PATH } from "../../core/paths.js";
import { ensureDir } from "../../core/utils.js";

const CODEX_HOOKS_JSON = join(homedir(), ".codex", "hooks.json");
const CODEX_HOME = join(homedir(), ".codex");

/**
 * Build the `codex` argv.
 *
 * - `mcp_servers.loom.env` is passed on every launch (fresh and resume)
 *   so the MCP child sees this branch's LOOM_SESSION/LOOM_BRANCH.
 * - `developer_instructions` is only passed on fresh launches. On resume
 *   Codex does NOT regenerate the developer role message from this flag
 *   (verified against Codex source `build_initial_context` and empirical
 *   tests); the developer message in the rollout is the sole authority
 *   for what the model sees. For fork children loom writes the correct
 *   developer message directly into the child's synthesized rollout, so
 *   passing `-c developer_instructions` at child resume would be a no-op
 *   at best and misleading (it only lands in turn_context, which is not
 *   sent to the model) — we omit it.
 */
export function codexBuildLaunchCommand(opts: LaunchCommandOpts): string[] {
  const mcpEnvToml =
    `mcp_servers.loom.env={` +
    `LOOM_SESSION=${tomlString(opts.loomSessionId)},` +
    `LOOM_BRANCH=${tomlString(opts.branchId)}` +
    `}`;
  const args = [
    "codex",
    "--dangerously-bypass-approvals-and-sandbox",
    "-c",
    mcpEnvToml,
  ];
  if (opts.resume) {
    args.push("resume", opts.agentSessionId);
  } else {
    // Fresh launch: inject the loom system prompt via developer_instructions
    // so Codex's build_initial_context writes it into the developer message
    // at turn 1.
    const developerInstrToml =
      `developer_instructions=${tomlString(opts.systemPromptText)}`;
    args.push("-c", developerInstrToml);
    // Codex 0.120+ does not persist any rollout file until the first
    // user turn. Seed an initial prompt so loom can discover the real
    // session id immediately.
    args.push("你好");
  }
  return args;
}

/** TOML basic string (double-quoted with \\ and \" escapes). */
function tomlString(s: string): string {
  const escaped = s
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"')
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r")
    .replace(/\t/g, "\\t");
  return `"${escaped}"`;
}

// Note: we intentionally do NOT use TOML multi-line literal strings
// (`'''...'''`) because those contain literal single quotes that collide
// with the shell-single-quote wrapping applied by writeLaunchScript. A
// basic double-quoted TOML string with `\n` escapes is safely embeddable
// inside `'...'` and decodes back to the original multi-line text when
// Codex parses TOML.

/**
 * Codex needs:
 *   1. MCP server registered at global scope via `codex mcp add loom`
 *   2. hooks.json at ~/.codex/hooks.json with a Stop handler
 *   3. `codex_hooks` feature enabled
 *
 * All three are idempotent (re-run safe).
 */
export function codexEnsureGlobalConfig(opts: EnsureGlobalConfigOpts): void {
  ensureDir(CODEX_HOME);

  // 1. (Re-)register MCP server with our server path.
  spawnSync("codex", ["mcp", "remove", "loom"], { stdio: "ignore" });
  const addRes = spawnSync(
    "codex",
    ["mcp", "add", "loom", "--", "node", opts.mcpServerPath],
    { encoding: "utf-8" },
  );
  if (addRes.status !== 0) {
    throw new Error(
      `codex mcp add failed: ${addRes.stderr || addRes.stdout || ""}`,
    );
  }

  // 2. Install hooks.json pointing to our compiled Stop hook.
  const hooks = {
    hooks: {
      Stop: [
        {
          hooks: [
            {
              type: "command",
              command: `node ${CODEX_STOP_HOOK_PATH}`,
              timeout: 60,
            },
          ],
        },
      ],
    },
  };
  writeFileSync(CODEX_HOOKS_JSON, JSON.stringify(hooks, null, 2));

  // 3. Enable the codex_hooks feature flag (under development -> needs opt-in).
  spawnSync("codex", ["features", "enable", "codex_hooks"], {
    stdio: "ignore",
  });
}
