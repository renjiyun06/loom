/**
 * Codex-side fork-call location and child-session synthesis.
 *
 * Codex rollout entries we care about:
 *   - { type: "session_meta", payload: { id, cwd, ... } }
 *   - { type: "event_msg", payload: { type: "task_started", turn_id } }
 *   - { type: "event_msg", payload: { type: "task_complete", turn_id, ... } }
 *   - { type: "response_item", payload: { type: "function_call",
 *                                         name, arguments, call_id } }
 *   - { type: "response_item", payload: { type: "function_call_output",
 *                                         call_id, output } }
 *
 * The Stop hook gives us the `turn_id` of the turn that just ended.
 * We locate the task_started/task_complete window for that turn and
 * search for a function_call whose name ends in `__fork` (full form
 * `mcp__loom__fork`).
 */

import { randomUUID } from "node:crypto";
import type {
  BuildChildSessionOpts,
  Entry,
  ForkLocation,
} from "../types.js";
import { readCodexEntries } from "./session-file.js";
import { sleep } from "../../core/utils.js";

function entryType(e: Entry): string {
  return String((e as any).type ?? "");
}

function payloadType(e: Entry): string {
  const p = (e as any).payload;
  return String(p?.type ?? "");
}

function isTaskStartedFor(e: Entry, turnId: string): boolean {
  return (
    entryType(e) === "event_msg" &&
    payloadType(e) === "task_started" &&
    String((e as any).payload?.turn_id ?? "") === turnId
  );
}

function isTaskCompleteFor(e: Entry, turnId: string): boolean {
  return (
    entryType(e) === "event_msg" &&
    payloadType(e) === "task_complete" &&
    String((e as any).payload?.turn_id ?? "") === turnId
  );
}

function isForkFunctionCall(e: Entry): boolean {
  if (entryType(e) !== "response_item") return false;
  if (payloadType(e) !== "function_call") return false;
  const name = String((e as any).payload?.name ?? "");
  return /(^|__)fork$/.test(name);
}

function locateForkInTurn(
  entries: Entry[],
  turnId: string,
): { index: number; callId: string } | null {
  let startIdx = -1;
  let endIdx = entries.length;
  for (let i = 0; i < entries.length; i++) {
    if (startIdx < 0 && isTaskStartedFor(entries[i], turnId)) {
      startIdx = i;
    } else if (startIdx >= 0 && isTaskCompleteFor(entries[i], turnId)) {
      endIdx = i;
      break;
    }
  }
  if (startIdx < 0) return null;
  for (let i = startIdx + 1; i < endIdx; i++) {
    if (isForkFunctionCall(entries[i])) {
      const callId = String((entries[i] as any).payload?.call_id ?? "");
      return { index: i, callId };
    }
  }
  return null;
}

export async function codexWaitForForkCall(
  parentFile: string,
  turnId: string,
  options: { timeoutMs?: number; pollIntervalMs?: number } = {},
): Promise<ForkLocation> {
  const timeoutMs = options.timeoutMs ?? 5_000;
  const interval = options.pollIntervalMs ?? 100;
  const started = Date.now();
  while (true) {
    const entries = readCodexEntries(parentFile);
    const hit = locateForkInTurn(entries, turnId);
    if (hit) {
      return {
        entries,
        forkIndex: hit.index,
        callId: hit.callId,
        turnId,
      };
    }
    if (Date.now() - started > timeoutMs) {
      throw new Error(
        `codexWaitForForkCall: no fork function_call found in turn ${turnId} ` +
          `within ${parentFile} after ${timeoutMs}ms`,
      );
    }
    await sleep(interval);
  }
}

function nowIso(): string {
  return new Date().toISOString();
}

function synthFunctionCallOutput(opts: {
  callId: string;
  outputText: string;
}): Entry {
  return {
    timestamp: nowIso(),
    type: "response_item",
    payload: {
      type: "function_call_output",
      call_id: opts.callId,
      output: opts.outputText,
    },
  };
}

function synthTaskCompleteForTurn(turnId: string): Entry {
  return {
    timestamp: nowIso(),
    type: "event_msg",
    payload: {
      type: "task_complete",
      turn_id: turnId,
      last_agent_message: null,
      completed_at: Math.floor(Date.now() / 1000),
      duration_ms: 0,
    },
  };
}

/**
 * For inheritContext=false synthesize a minimal session that looks like
 * "the agent just called fork and got back the birth announcement".
 */
function synthMinimalCodexSession(opts: {
  childAgentSessionId: string;
  cwd: string;
  instruction: string;
  birthText: string;
}): Entry[] {
  const turnId = randomUUID();
  const callId = `call_${randomUUID().replace(/-/g, "").slice(0, 24)}`;
  const sessionMeta: Entry = {
    timestamp: nowIso(),
    type: "session_meta",
    payload: {
      id: opts.childAgentSessionId,
      timestamp: nowIso(),
      cwd: opts.cwd,
      originator: "loom-synthetic",
      cli_version: "0.0.0",
      source: "loom",
      model_provider: "openai",
    },
  };
  const taskStarted: Entry = {
    timestamp: nowIso(),
    type: "event_msg",
    payload: {
      type: "task_started",
      turn_id: turnId,
      model_context_window: 0,
      collaboration_mode_kind: "default",
    },
  };
  const turnContext: Entry = {
    timestamp: nowIso(),
    type: "turn_context",
    payload: { turn_id: turnId, cwd: opts.cwd },
  };
  const userMsg: Entry = {
    timestamp: nowIso(),
    type: "response_item",
    payload: {
      type: "message",
      role: "user",
      content: [{ type: "input_text", text: opts.instruction }],
    },
  };
  const forkCall: Entry = {
    timestamp: nowIso(),
    type: "response_item",
    payload: {
      type: "function_call",
      name: "mcp__loom__fork",
      arguments: JSON.stringify({
        instruction: opts.instruction,
        inherit_context: false,
      }),
      call_id: callId,
    },
  };
  const forkOut = synthFunctionCallOutput({
    callId,
    outputText: opts.birthText,
  });
  const taskComplete = synthTaskCompleteForTurn(turnId);
  return [sessionMeta, taskStarted, turnContext, userMsg, forkCall, forkOut, taskComplete];
}

export function codexBuildChildSessionEntries(
  opts: BuildChildSessionOpts,
): Entry[] {
  if (!opts.inheritContext) {
    return synthMinimalCodexSession({
      childAgentSessionId: opts.childAgentSessionId,
      cwd: opts.cwd,
      instruction: opts.instruction,
      birthText: opts.birthAnnouncementText,
    });
  }

  // inheritContext=true: slice parent prefix up to and including the
  // fork function_call, change session_meta.id to child's id, then
  // append the synthetic function_call_output + task_complete closure.
  const prefix = opts.forkLocation.entries
    .slice(0, opts.forkLocation.forkIndex + 1)
    .map((e, i) => {
      if (i === 0 && entryType(e) === "session_meta") {
        const copy = structuredClone(e) as any;
        if (copy.payload) copy.payload.id = opts.childAgentSessionId;
        return copy as Entry;
      }
      return e;
    });

  const turnId = opts.forkLocation.turnId ?? findTurnIdAround(prefix, opts.forkLocation.forkIndex);
  const forkOut = synthFunctionCallOutput({
    callId: opts.forkLocation.callId,
    outputText: opts.birthAnnouncementText,
  });
  const result: Entry[] = [...prefix, forkOut];
  if (turnId) {
    result.push(synthTaskCompleteForTurn(turnId));
  }
  return result;
}

/**
 * When ForkLocation.turnId is not set (shouldn't happen for Codex paths
 * but guard anyway), derive it from the surrounding task_started entry.
 */
function findTurnIdAround(entries: Entry[], forkIdx: number): string | null {
  for (let i = forkIdx; i >= 0; i--) {
    const e = entries[i];
    if (entryType(e) === "event_msg" && payloadType(e) === "task_started") {
      return String((e as any).payload?.turn_id ?? "") || null;
    }
  }
  return null;
}
