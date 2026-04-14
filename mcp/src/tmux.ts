/**
 * tmux wrapper. Each branch's Claude Code instance runs in a named tmux
 * session; send-keys delivers cross-branch messages into the target pane.
 */

import { spawnSync } from "node:child_process";

export function tmuxSessionName(
  loomSessionId: string,
  branchId: string,
): string {
  return `loom-${loomSessionId}-${branchId}`;
}

export function sessionExists(name: string): boolean {
  const r = spawnSync("tmux", ["has-session", "-t", name], { stdio: "ignore" });
  return r.status === 0;
}

export interface NewSessionOpts {
  name: string;
  cwd: string;
  command: string;
  env?: Record<string, string>;
}

export function newSession(opts: NewSessionOpts): void {
  const args = ["new-session", "-d", "-s", opts.name, "-c", opts.cwd];
  for (const [k, v] of Object.entries(opts.env ?? {})) {
    args.push("-e", `${k}=${v}`);
  }
  args.push(opts.command);

  const r = spawnSync("tmux", args, { encoding: "utf-8" });
  if (r.status !== 0) {
    throw new Error(`tmux new-session failed: ${r.stderr || r.stdout || ""}`);
  }
}

export function killSession(name: string): void {
  spawnSync("tmux", ["kill-session", "-t", name], { stdio: "ignore" });
}

/**
 * Send a line of text (followed by Enter) into the target pane. The
 * caller is responsible for serialization — use `withSendLock` around
 * this when multiple branches might send to the same target
 * concurrently.
 */
export function sendKeys(name: string, text: string): void {
  // -l = literal mode; tmux writes the bytes as-is, no keyword translation.
  const rText = spawnSync("tmux", ["send-keys", "-t", name, "-l", text], {
    encoding: "utf-8",
  });
  if (rText.status !== 0) {
    throw new Error(`tmux send-keys (text) failed: ${rText.stderr || ""}`);
  }
  const rEnter = spawnSync("tmux", ["send-keys", "-t", name, "Enter"], {
    encoding: "utf-8",
  });
  if (rEnter.status !== 0) {
    throw new Error(`tmux send-keys (Enter) failed: ${rEnter.stderr || ""}`);
  }
}
