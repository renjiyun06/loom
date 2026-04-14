/**
 * Launch a Claude Code instance for a Loom branch inside a tmux session.
 *
 * Used by fork (to start a newly-created child) and by send (to
 * auto-start a dormant branch's agent on demand). Responsible for:
 *   - wiring up the `loom` MCP server via `--mcp-config`
 *   - substituting `{{BRANCH_ID}}` into the system prompt and passing
 *     the result via `--append-system-prompt`
 *   - exporting `LOOM_SESSION` / `LOOM_BRANCH` so the MCP server child
 *     process can identify itself
 */

import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { newSession, tmuxSessionName } from "./tmux.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// This file compiles to `<repo>/mcp/dist/launcher.js`, so the repo root
// is two levels up from __dirname.
const REPO_ROOT = resolve(__dirname, "..", "..");
const MCP_DIST = join(REPO_ROOT, "mcp", "dist", "index.js");
const POST_FORK_HOOK = join(REPO_ROOT, "mcp", "dist", "hooks", "post-fork.js");
const SYSTEM_PROMPT_FILE = join(REPO_ROOT, "system-prompt.md");

const LOOM_HOME = join(homedir(), ".loom");
const MCP_CONFIG_PATH = join(LOOM_HOME, "mcp-config.json");
const SETTINGS_PATH = join(LOOM_HOME, "settings.json");

function shellQuote(s: string): string {
  // Wrap in single quotes; escape any embedded single quotes.
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function writeMcpConfig(): string {
  const config = {
    mcpServers: {
      loom: {
        command: "node",
        args: [MCP_DIST],
      },
    },
  };
  writeFileSync(MCP_CONFIG_PATH, JSON.stringify(config, null, 2));
  return MCP_CONFIG_PATH;
}

function writeLoomSettings(): string {
  const settings = {
    hooks: {
      PostToolUse: [
        {
          matcher: ".*fork.*",
          hooks: [
            {
              type: "command",
              command: `node ${POST_FORK_HOOK}`,
            },
          ],
        },
      ],
    },
  };
  writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2));
  return SETTINGS_PATH;
}

function renderSystemPrompt(branchId: string): string {
  const template = readFileSync(SYSTEM_PROMPT_FILE, "utf-8");
  return template.replace(/\{\{BRANCH_ID\}\}/g, branchId);
}

export interface LaunchOpts {
  sessionId: string;
  branchId: string;
  ccSessionId: string;
  cwd: string;
}

export function launchCc(opts: LaunchOpts): void {
  const mcpConfigPath = writeMcpConfig();
  const settingsPath = writeLoomSettings();
  const systemPrompt = renderSystemPrompt(opts.branchId);

  const args = [
    "claude",
    "--resume",
    opts.ccSessionId,
    "--mcp-config",
    mcpConfigPath,
    "--settings",
    settingsPath,
    "--append-system-prompt",
    systemPrompt,
    "--dangerously-skip-permissions",
  ];
  const command = args.map(shellQuote).join(" ");

  newSession({
    name: tmuxSessionName(opts.sessionId, opts.branchId),
    cwd: opts.cwd,
    command,
    env: {
      LOOM_SESSION: opts.sessionId,
      LOOM_BRANCH: opts.branchId,
    },
  });
}
