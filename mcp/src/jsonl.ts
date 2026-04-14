/**
 * Helpers for manipulating Claude Code JSONL session files.
 *
 * Claude Code stores each session as a JSONL at:
 *   ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl
 *
 * Loom creates projections of these files when forking a child branch.
 */

import { randomBytes, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export function encodeCwd(cwd: string): string {
  // Claude Code's directory-encoding convention: replace '/' with '-'.
  // e.g. /home/lamarck/project → -home-lamarck-project
  return cwd.replace(/\//g, "-");
}

export function sessionFilePath(cwd: string, ccSessionId: string): string {
  return join(
    homedir(),
    ".claude",
    "projects",
    encodeCwd(cwd),
    `${ccSessionId}.jsonl`,
  );
}

// Generic entry shape — we treat JSONL entries as opaque JSON objects,
// touching only the few fields we actually care about.
export type Entry = Record<string, unknown>;

export function readEntries(path: string): Entry[] {
  const text = readFileSync(path, "utf-8");
  const entries: Entry[] = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      entries.push(JSON.parse(trimmed));
    } catch {
      // skip malformed lines silently
    }
  }
  return entries;
}

export function writeEntries(path: string, entries: Entry[]): void {
  mkdirSync(dirname(path), { recursive: true });
  const content = entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
  writeFileSync(path, content);
}

/**
 * Return a shallow copy of the entry with `sessionId` replaced, if the
 * field exists. Entries without a sessionId (e.g. file-history-snapshot)
 * are returned unchanged.
 */
export function rewriteSessionId(entry: Entry, newSessionId: string): Entry {
  if (!("sessionId" in entry)) return entry;
  return { ...entry, sessionId: newSessionId };
}

function isForkToolName(name: unknown): boolean {
  if (typeof name !== "string") return false;
  // CC may store MCP tool names as `fork` or `mcp__<server>__fork`.
  return name === "fork" || /(^|__)fork$/.test(name);
}

/**
 * Find the assistant entry whose content contains a tool_use with the
 * given id. Used by the PostToolUse hook to locate *exactly this* fork
 * call's entry in the parent JSONL (the `tool_use_id` comes from the
 * hook's stdin payload and authoritatively identifies the call).
 */
export function findForkToolUseById(
  entries: Entry[],
  toolUseId: string,
): { index: number; entryUuid: string } | null {
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i] as any;
    if (e?.type !== "assistant") continue;
    const blocks = e?.message?.content;
    if (!Array.isArray(blocks)) continue;
    for (const b of blocks) {
      if (
        b?.type === "tool_use" &&
        isForkToolName(b?.name) &&
        b?.id === toolUseId
      ) {
        return { index: i, entryUuid: e.uuid };
      }
    }
  }
  return null;
}

function randomHexId(bytes = 4): string {
  return randomBytes(bytes).toString("hex");
}

function nowIso(): string {
  return new Date().toISOString();
}

/**
 * The child-version fork tool_result — the "birth announcement" that
 * tells the newly spawned agent who it is.
 */
export function createChildForkToolResult(opts: {
  toolUseId: string;
  childBranchId: string;
  parentBranchId: string;
  inheritContext: boolean;
  ccSessionId: string;
  parentUuid: string;
  cwd: string;
}): Entry {
  const text = opts.inheritContext
    ? `You are branch ${opts.childBranchId}, forked from branch ${opts.parentBranchId}.`
    : `You are branch ${opts.childBranchId}, forked from branch ${opts.parentBranchId} without context inheritance.`;

  return {
    parentUuid: opts.parentUuid,
    isSidechain: false,
    type: "user",
    message: {
      role: "user",
      content: [
        {
          type: "tool_result",
          tool_use_id: opts.toolUseId,
          content: text,
          is_error: false,
        },
      ],
    },
    uuid: randomUUID(),
    timestamp: nowIso(),
    sessionId: opts.ccSessionId,
    sourceToolAssistantUUID: opts.parentUuid,
    userType: "external",
    entrypoint: "cli",
    cwd: opts.cwd,
    version: "2.1.104",
  };
}

/**
 * Synthesize a minimal assistant entry containing a fork tool_use, for
 * use when inherit_context=false (the child has no shared past).
 */
export function createSyntheticForkCall(opts: {
  instruction: string;
  ccSessionId: string;
  cwd: string;
}): { assistantEntry: Entry; toolUseId: string; entryUuid: string } {
  const toolUseId = `toolu_${randomHexId(12)}`;
  const msgId = `msg_${randomHexId(12)}`;
  const entryUuid = randomUUID();

  const assistantEntry: Entry = {
    parentUuid: null,
    isSidechain: false,
    type: "assistant",
    message: {
      id: msgId,
      type: "message",
      role: "assistant",
      model: "claude-opus-4-6",
      content: [
        {
          type: "tool_use",
          id: toolUseId,
          name: "fork",
          input: {
            instruction: opts.instruction,
            inherit_context: false,
          },
        },
      ],
      stop_reason: "tool_use",
      stop_sequence: null,
      usage: { input_tokens: 0, output_tokens: 0 },
    },
    uuid: entryUuid,
    timestamp: nowIso(),
    sessionId: opts.ccSessionId,
    requestId: `req_${randomHexId(12)}`,
    userType: "external",
    entrypoint: "cli",
    cwd: opts.cwd,
    version: "2.1.104",
  };

  return { assistantEntry, toolUseId, entryUuid };
}

/** Generate a short branch id (8 hex chars). */
export function generateBranchId(): string {
  return randomHexId(4);
}

/** Generate a CC session uuid (v4). */
export function generateCcSessionId(): string {
  return randomUUID();
}
