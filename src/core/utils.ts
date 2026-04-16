/**
 * Small utilities shared across Loom: sleep, file locks, shell quoting,
 * and paths to per-branch runtime files.
 */

import {
  closeSync,
  mkdirSync,
  openSync,
  unlinkSync,
} from "node:fs";
import { join } from "node:path";
import { PENDING_FORKS_DIR, SEND_LOCKS_DIR } from "./paths.js";

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function pendingForkPath(agentSessionId: string): string {
  return join(PENDING_FORKS_DIR, `${agentSessionId}.json`);
}

export function sendLockPath(tmuxName: string): string {
  return join(SEND_LOCKS_DIR, `${tmuxName}.lock`);
}

/**
 * Wrap a piece of text in single quotes suitable for bash exec, escaping
 * any embedded single quotes. Safe for nested quoting.
 */
export function shellQuote(s: string): string {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

/**
 * Acquire an advisory lock via exclusive file creation (`O_EXCL`) and
 * release it on completion. Used to serialize send-keys calls targeting
 * the same tmux pane so their keystrokes do not interleave.
 */
export async function withFileLock<T>(
  lockPath: string,
  fn: () => Promise<T> | T,
  opts: { retryMs?: number; timeoutMs?: number } = {},
): Promise<T> {
  const retryMs = opts.retryMs ?? 50;
  const timeoutMs = opts.timeoutMs ?? 10_000;
  const started = Date.now();
  mkdirSync(SEND_LOCKS_DIR, { recursive: true });
  let fd: number | null = null;
  while (fd === null) {
    try {
      fd = openSync(lockPath, "wx");
    } catch (err) {
      if (Date.now() - started > timeoutMs) {
        throw new Error(
          `withFileLock: timed out acquiring lock at ${lockPath}`,
        );
      }
      await sleep(retryMs);
    }
  }
  try {
    return await fn();
  } finally {
    try {
      closeSync(fd);
      unlinkSync(lockPath);
    } catch {
      // best-effort
    }
  }
}

/**
 * Generate a short hex id (default 8 chars) for branch ids.
 */
export function randomHex(bytes = 4): string {
  const arr = new Uint8Array(bytes);
  for (let i = 0; i < bytes; i++) {
    arr[i] = Math.floor(Math.random() * 256);
  }
  return Array.from(arr, (b) => b.toString(16).padStart(2, "0")).join("");
}

export function nowMs(): number {
  return Date.now();
}

export function nowIso(): string {
  return new Date().toISOString();
}

export function ensureDir(path: string): void {
  mkdirSync(path, { recursive: true });
}

export function ensurePendingForksDir(): void {
  ensureDir(PENDING_FORKS_DIR);
}
