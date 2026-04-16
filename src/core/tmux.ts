/**
 * Thin wrapper around the `tmux` CLI. Each Loom branch runs inside its
 * own named tmux session. All functions shell out synchronously.
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

export function listLoomSessions(): string[] {
  const r = spawnSync("tmux", ["list-sessions", "-F", "#S"], {
    encoding: "utf-8",
  });
  if (r.status !== 0) return [];
  return r.stdout
    .split("\n")
    .map((s) => s.trim())
    .filter((s) => s.startsWith("loom-"));
}

export interface NewSessionOpts {
  name: string;
  cwd: string;
  /** Raw command string (already properly quoted) to run inside the session. */
  command: string;
  env?: Record<string, string>;
  /** true = tmux new-session -d (detached); false = foreground (exec). */
  detached?: boolean;
}

export function newSession(opts: NewSessionOpts): void {
  const args = ["new-session"];
  if (opts.detached !== false) args.push("-d");
  args.push("-s", opts.name, "-c", opts.cwd);
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
 * Inject a line of text (followed by Enter) into the target pane.
 * Callers are responsible for serialization via file-lock when multiple
 * senders might race; see utils.withFileLock.
 */
export function sendKeys(name: string, text: string): void {
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
