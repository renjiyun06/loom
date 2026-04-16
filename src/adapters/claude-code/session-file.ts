/**
 * Claude Code session file layout:
 *   ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
 * cwd is encoded by replacing `/` with `-`. One JSON object per line.
 */

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { Entry } from "../types.js";

export function encodeCwd(cwd: string): string {
  return cwd.replace(/\//g, "-");
}

export function ccSessionFilePath(cwd: string, agentSessionId: string): string {
  return join(
    homedir(),
    ".claude",
    "projects",
    encodeCwd(cwd),
    `${agentSessionId}.jsonl`,
  );
}

export function readCcEntries(path: string): Entry[] {
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
      // skip malformed line
    }
  }
  return out;
}

export function writeCcEntries(path: string, entries: Entry[]): void {
  mkdirSync(dirname(path), { recursive: true });
  const body = entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
  writeFileSync(path, body);
}

/**
 * Rewrite the `sessionId` field of an entry to the new id if present.
 * CC embeds sessionId in most entry types; we need every entry in a
 * child's projection to carry the child's id.
 */
export function rewriteSessionIdInEntry(
  entry: Entry,
  newSessionId: string,
): Entry {
  if (!("sessionId" in entry)) return entry;
  return { ...entry, sessionId: newSessionId };
}
