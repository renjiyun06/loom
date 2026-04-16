/**
 * Pre-flight checks for loom CLI commands.
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import type { AgentType } from "../types.js";
import { MCP_SERVER_PATH } from "../core/paths.js";

function hasCommand(cmd: string): boolean {
  const r = spawnSync("which", [cmd], { stdio: "ignore" });
  return r.status === 0;
}

export function requireTools(tools: string[]): void {
  const missing = tools.filter((t) => !hasCommand(t));
  if (missing.length) {
    console.error(
      `loom: missing required command(s): ${missing.join(", ")}`,
    );
    process.exit(1);
  }
}

export function requireBuilt(): void {
  if (!existsSync(MCP_SERVER_PATH)) {
    console.error(
      `loom: MCP server not built.\n      run \`npm install && npm run build\` first.`,
    );
    process.exit(1);
  }
}

export function requireAgentBinary(agent: AgentType): void {
  const binary = agent === "claude-code" ? "claude" : "codex";
  if (!hasCommand(binary)) {
    console.error(
      `loom: agent '${agent}' requires the \`${binary}\` binary in PATH.`,
    );
    process.exit(1);
  }
}
