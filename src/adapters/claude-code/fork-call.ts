/**
 * CC-side fork-call location and child-session synthesis.
 *
 * Input: parent session JSONL entries and the exact `tool_use_id`
 * returned by the PostToolUse hook.
 *
 * Output: ForkLocation + a function that builds the child session.
 */

import { randomBytes, randomUUID } from "node:crypto";
import type {
  BuildChildSessionOpts,
  Entry,
  ForkLocation,
} from "../types.js";
import { readCcEntries, rewriteSessionIdInEntry } from "./session-file.js";
import { sleep } from "../../core/utils.js";

function isForkToolName(name: unknown): boolean {
  if (typeof name !== "string") return false;
  return name === "fork" || /(^|__)fork$/.test(name);
}

function findForkToolUseById(
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

export async function ccWaitForForkCall(
  parentFile: string,
  toolUseId: string,
  options: { timeoutMs?: number; pollIntervalMs?: number } = {},
): Promise<ForkLocation> {
  const timeoutMs = options.timeoutMs ?? 2_000;
  const interval = options.pollIntervalMs ?? 200;
  const started = Date.now();
  while (true) {
    const entries = readCcEntries(parentFile);
    const hit = findForkToolUseById(entries, toolUseId);
    if (hit) {
      return {
        entries,
        forkIndex: hit.index,
        callId: toolUseId,
      };
    }
    if (Date.now() - started > timeoutMs) {
      throw new Error(
        `ccWaitForForkCall: tool_use ${toolUseId} not found in ${parentFile} ` +
          `after ${timeoutMs}ms`,
      );
    }
    await sleep(interval);
  }
}

function randomHexId(bytes = 4): string {
  return randomBytes(bytes).toString("hex");
}

function nowIso(): string {
  return new Date().toISOString();
}

/**
 * The child-version fork tool_result — the birth announcement entry
 * that tells the new agent who it is.
 */
function createChildForkToolResult(opts: {
  toolUseId: string;
  birthText: string;
  agentSessionId: string;
  parentUuid: string;
  cwd: string;
}): Entry {
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
          content: opts.birthText,
          is_error: false,
        },
      ],
    },
    uuid: randomUUID(),
    timestamp: nowIso(),
    sessionId: opts.agentSessionId,
    sourceToolAssistantUUID: opts.parentUuid,
    userType: "external",
    entrypoint: "cli",
    cwd: opts.cwd,
    version: "2.1.104",
  };
}

/**
 * Synthesize a minimal assistant entry containing a fork tool_use, for
 * use when inheritContext=false (child has no shared past).
 */
function createSyntheticForkCall(opts: {
  instruction: string;
  agentSessionId: string;
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
          input: { instruction: opts.instruction, inherit_context: false },
        },
      ],
      stop_reason: "tool_use",
      stop_sequence: null,
      usage: { input_tokens: 0, output_tokens: 0 },
    },
    uuid: entryUuid,
    timestamp: nowIso(),
    sessionId: opts.agentSessionId,
    requestId: `req_${randomHexId(12)}`,
    userType: "external",
    entrypoint: "cli",
    cwd: opts.cwd,
    version: "2.1.104",
  };
  return { assistantEntry, toolUseId, entryUuid };
}

export function ccBuildChildSessionEntries(opts: BuildChildSessionOpts): Entry[] {
  if (opts.inheritContext) {
    const slice = opts.forkLocation.entries
      .slice(0, opts.forkLocation.forkIndex + 1)
      .map((e) => rewriteSessionIdInEntry(e, opts.childAgentSessionId));
    const parentForkEntry = opts.forkLocation.entries[opts.forkLocation.forkIndex] as any;
    const parentUuid: string = parentForkEntry?.uuid ?? "";
    const birth = createChildForkToolResult({
      toolUseId: opts.forkLocation.callId,
      birthText: opts.birthAnnouncementText,
      agentSessionId: opts.childAgentSessionId,
      parentUuid,
      cwd: opts.cwd,
    });
    return [...slice, birth];
  }

  const synth = createSyntheticForkCall({
    instruction: opts.instruction,
    agentSessionId: opts.childAgentSessionId,
    cwd: opts.cwd,
  });
  const birth = createChildForkToolResult({
    toolUseId: synth.toolUseId,
    birthText: opts.birthAnnouncementText,
    agentSessionId: opts.childAgentSessionId,
    parentUuid: synth.entryUuid,
    cwd: opts.cwd,
  });
  return [synth.assistantEntry, birth];
}
