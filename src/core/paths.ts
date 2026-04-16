/**
 * Path constants used across Loom. All of these live under $HOME so Loom
 * can be run as a regular user without escalation.
 */
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const LOOM_HOME = join(homedir(), ".loom");
export const LOOM_DB = join(LOOM_HOME, "loom.db");
export const PENDING_FORKS_DIR = join(LOOM_HOME, "pending-forks");
export const SEND_LOCKS_DIR = join(LOOM_HOME, "send-locks");
export const LOOM_DEBUG_LOG = join(LOOM_HOME, "debug.log");

/**
 * Locate the Loom repo root at runtime. Compiled code lives in
 * `<repo>/dist/core/paths.js`, so the repo root is two `..` up from
 * the compiled file's directory.
 */
const __filename = fileURLToPath(import.meta.url);
export const REPO_ROOT = resolve(dirname(__filename), "..", "..");

export const DIST_DIR = join(REPO_ROOT, "dist");
export const MCP_SERVER_PATH = join(DIST_DIR, "mcp", "server.js");
export const CC_POST_HOOK_PATH = join(DIST_DIR, "hooks", "claude-code-post-tool-use.js");
export const CODEX_STOP_HOOK_PATH = join(DIST_DIR, "hooks", "codex-stop.js");

export const SYSTEM_PROMPT_TEMPLATE = join(REPO_ROOT, "system-prompt.md");

/** CC-side MCP / settings config loom writes into ~/.loom/. */
export const CC_MCP_CONFIG = join(LOOM_HOME, "mcp-config.json");
export const CC_SETTINGS = join(LOOM_HOME, "settings.json");

/** Per-branch runtime artifact paths written by Loom on launch. */
export function launchScriptPath(sid: string, branchId: string): string {
  return join(LOOM_HOME, `session-${sid}-${branchId}-launch.sh`);
}
export function promptFilePath(sid: string, branchId: string): string {
  return join(LOOM_HOME, `session-${sid}-${branchId}-prompt.txt`);
}

/** Global lock for `loom new` serialization (agent-specific discovery flow). */
export const NEW_SESSION_LOCK = join(LOOM_HOME, "new-session.lock");
