/**
 * Write a per-branch launch script that tmux will exec. This sidesteps
 * the terminal-capability-query leak that occurs when tmux's default
 * shell spends time parsing a multi-kilobyte command line before
 * handing control to the agent.
 *
 * The generated script is tiny: a shebang and a single `exec <agent>
 * <args...>`. Tmux loads it instantly, bash becomes the agent, and the
 * agent starts reading stdin before any DA1/DA2 responses arrive.
 */

import { chmodSync, writeFileSync } from "node:fs";
import { launchScriptPath, promptFilePath } from "./paths.js";
import { ensureDir, shellQuote } from "./utils.js";
import { dirname } from "node:path";
import { LOOM_HOME } from "./paths.js";

export interface WriteLaunchScriptOpts {
  loomSessionId: string;
  branchId: string;
  argv: string[];
}

export function writeLaunchScript(opts: WriteLaunchScriptOpts): string {
  ensureDir(LOOM_HOME);
  const path = launchScriptPath(opts.loomSessionId, opts.branchId);
  const quoted = opts.argv.map(shellQuote).join(" ");
  const body = `#!/usr/bin/env bash\nset -euo pipefail\nexec ${quoted}\n`;
  writeFileSync(path, body);
  chmodSync(path, 0o755);
  return path;
}

/**
 * For agents whose launch involves a giant system-prompt text (CC's
 * --append-system-prompt), writing the prompt to disk and referencing
 * it via `"$(cat <path>)"` inside the launch script keeps the launch
 * script readable and side-steps ARG_MAX.
 */
export function writePromptFile(
  loomSessionId: string,
  branchId: string,
  text: string,
): string {
  ensureDir(LOOM_HOME);
  const path = promptFilePath(loomSessionId, branchId);
  writeFileSync(path, text);
  return path;
}
