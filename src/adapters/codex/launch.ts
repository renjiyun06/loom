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
import { ensureDir } from "../../core/utils.js";

const CODEX_HOOKS_JSON = join(homedir(), ".codex", "hooks.json");
const CODEX_HOME = join(homedir(), ".codex");

/**
 * Build the `codex` argv. The two -c overrides inject:
 *   - per-launch MCP env (so each Codex process's spawned MCP child
 *     sees this branch's LOOM_SESSION/LOOM_BRANCH)
 *   - developer_instructions (equivalent of CC's --append-system-prompt)
 */
export function codexBuildLaunchCommand(opts: LaunchCommandOpts): string[] {
  const mcpEnvToml =
    `mcp_servers.loom.env={` +
    `LOOM_SESSION=${tomlString(opts.loomSessionId)},` +
    `LOOM_BRANCH=${tomlString(opts.branchId)}` +
    `}`;
  const developerInstrToml =
    `developer_instructions=${tomlTripleString(opts.systemPromptText)}`;
  const args = [
    "codex",
    "--skip-git-repo-check",
    "-c",
    mcpEnvToml,
    "-c",
    developerInstrToml,
  ];
  if (opts.resume) {
    args.push("resume", opts.agentSessionId);
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

/** TOML multi-line literal string (triple single-quoted) — supports
 *  multi-line text without escape processing. Newlines, quotes etc.
 *  pass through verbatim. Requires the content to not include `'''`.
 */
function tomlTripleString(s: string): string {
  if (s.includes("'''")) {
    // Fall back to double-quoted basic string with escapes.
    return tomlString(s);
  }
  return `'''\n${s}'''`;
}

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
              command: `node ${opts.hookScriptPath}`,
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
