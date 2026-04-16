/**
 * Codex rollout file layout:
 *   ~/.codex/sessions/YYYY/MM/DD/rollout-<ISO>-<uuid>.jsonl
 *
 * Codex buckets sessions by date rather than by cwd. `cwd` is embedded
 * in the first `session_meta` entry's payload and informational only;
 * the process cwd at resume time overrides it. To locate an existing
 * session file by id, we scan the directory tree.
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { Entry } from "../types.js";

const CODEX_SESSIONS_ROOT = join(homedir(), ".codex", "sessions");

export function codexSessionsRoot(): string {
  return CODEX_SESSIONS_ROOT;
}

/**
 * Build a fresh rollout filename in today's YYYY/MM/DD bucket using the
 * current UTC time. Used when creating a new child session file.
 */
function buildNewRolloutPath(agentSessionId: string): string {
  const now = new Date();
  const yyyy = String(now.getUTCFullYear());
  const mm = String(now.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(now.getUTCDate()).padStart(2, "0");
  const iso = now.toISOString().replace(/:/g, "-").replace(/\..+$/, "");
  const filename = `rollout-${iso}-${agentSessionId}.jsonl`;
  return join(CODEX_SESSIONS_ROOT, yyyy, mm, dd, filename);
}

/**
 * Scan ~/.codex/sessions for a rollout file whose name ends with
 * `-<id>.jsonl`. Returns null if not found.
 */
export function findCodexRolloutById(agentSessionId: string): string | null {
  if (!existsSync(CODEX_SESSIONS_ROOT)) return null;
  const suffix = `-${agentSessionId}.jsonl`;
  // Walk up to 4 levels deep (year/month/day/file).
  const hits: string[] = [];
  const walk = (dir: string, depth: number) => {
    if (hits.length) return;
    if (depth > 4) return;
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      const full = join(dir, name);
      let st;
      try {
        st = statSync(full);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        walk(full, depth + 1);
        if (hits.length) return;
      } else if (st.isFile() && name.endsWith(suffix)) {
        hits.push(full);
        return;
      }
    }
  };
  walk(CODEX_SESSIONS_ROOT, 0);
  return hits[0] ?? null;
}

/**
 * Return the canonical session file path for (cwd, agentSessionId).
 * cwd is ignored (Codex doesn't encode it in the filename).
 *
 * - If the file already exists somewhere under ~/.codex/sessions,
 *   return the existing path.
 * - Otherwise, return a new path in today's bucket.
 */
export function codexSessionFilePath(
  _cwd: string,
  agentSessionId: string,
): string {
  const existing = findCodexRolloutById(agentSessionId);
  return existing ?? buildNewRolloutPath(agentSessionId);
}

/**
 * Recursively walk ~/.codex/sessions/ and return all *.jsonl paths.
 * Used by the snapshot-before-launch step of new-session discovery.
 */
export function listAllCodexRollouts(): string[] {
  if (!existsSync(CODEX_SESSIONS_ROOT)) return [];
  const out: string[] = [];
  const walk = (dir: string, depth: number) => {
    if (depth > 4) return;
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      return;
    }
    for (const name of entries) {
      const full = join(dir, name);
      let st;
      try {
        st = statSync(full);
      } catch {
        continue;
      }
      if (st.isDirectory()) walk(full, depth + 1);
      else if (st.isFile() && name.endsWith(".jsonl")) out.push(full);
    }
  };
  walk(CODEX_SESSIONS_ROOT, 0);
  return out;
}

/**
 * Read the first line of a rollout file (session_meta) and return its
 * `payload.id`. Returns null if the file doesn't parse or doesn't have
 * a session_meta on line 1.
 */
export function readRolloutSessionId(path: string): string | null {
  try {
    const text = readFileSync(path, "utf-8");
    const firstLine = text.split("\n", 1)[0].trim();
    if (!firstLine) return null;
    const obj = JSON.parse(firstLine) as any;
    if (obj?.type !== "session_meta") return null;
    const id = obj?.payload?.id;
    return typeof id === "string" ? id : null;
  } catch {
    return null;
  }
}

export function readCodexEntries(path: string): Entry[] {
  let text: string;
  try {
    text = readFileSync(path, "utf-8");
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw err;
  }
  const out: Entry[] = [];
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    try {
      out.push(JSON.parse(t));
    } catch {
      // skip malformed
    }
  }
  return out;
}

export function writeCodexEntries(path: string, entries: Entry[]): void {
  mkdirSync(dirname(path), { recursive: true });
  const body = entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
  writeFileSync(path, body);
}
