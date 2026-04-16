/**
 * CC launch command builder and global-config writer.
 */

import { writeFileSync } from "node:fs";
import type {
  EnsureGlobalConfigOpts,
  LaunchCommandOpts,
} from "../types.js";
import {
  CC_MCP_CONFIG,
  CC_SETTINGS,
  CC_POST_HOOK_PATH,
} from "../../core/paths.js";
import { ensureDir } from "../../core/utils.js";
import { dirname } from "node:path";

export function ccBuildLaunchCommand(opts: LaunchCommandOpts): string[] {
  const args = ["claude"];
  if (opts.resume) {
    args.push("--resume", opts.agentSessionId);
  } else {
    args.push("--session-id", opts.agentSessionId);
  }
  args.push(
    "--mcp-config",
    CC_MCP_CONFIG,
    "--settings",
    CC_SETTINGS,
    "--append-system-prompt",
    opts.systemPromptText,
    "--dangerously-skip-permissions",
  );
  return args;
}

/**
 * Write ~/.loom/mcp-config.json and ~/.loom/settings.json so that every
 * CC launched by loom registers the loom MCP server and its
 * PostToolUse-based fork hook.
 */
export function ccEnsureGlobalConfig(opts: EnsureGlobalConfigOpts): void {
  ensureDir(dirname(CC_MCP_CONFIG));
  const mcpConfig = {
    mcpServers: {
      loom: {
        command: "node",
        args: [opts.mcpServerPath],
      },
    },
  };
  writeFileSync(CC_MCP_CONFIG, JSON.stringify(mcpConfig, null, 2));

  const settings = {
    hooks: {
      PostToolUse: [
        {
          matcher: ".*fork.*",
          hooks: [
            {
              type: "command",
              command: `node ${CC_POST_HOOK_PATH}`,
            },
          ],
        },
      ],
    },
  };
  writeFileSync(CC_SETTINGS, JSON.stringify(settings, null, 2));
}
