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
import { renderSystemPrompt } from "../../core/system-prompt.js";

const LOOM_PROMPT_ANCHOR = "# Loom Branch System";

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

/**
 * Derive the child's session_meta from the parent's first rollout entry.
 * Replaces `id` + both `timestamp`s (outer and `payload.timestamp`); every
 * other field (`cwd`, `originator`, `cli_version`, `source`,
 * `model_provider`, `base_instructions`, ...) is inherited verbatim so the
 * child keeps the same Codex system prompt and launch provenance.
 */
function inheritSessionMeta(
  parentFirstEntry: Entry,
  childAgentSessionId: string,
): Entry {
  if (entryType(parentFirstEntry) !== "session_meta") {
    throw new Error(
      `inheritSessionMeta: expected first entry type='session_meta', got '${entryType(parentFirstEntry)}'`,
    );
  }
  const copy = structuredClone(parentFirstEntry) as any;
  const now = nowIso();
  copy.timestamp = now;
  if (copy.payload) {
    copy.payload.id = childAgentSessionId;
    copy.payload.timestamp = now;
  }
  return copy as Entry;
}

/**
 * Rewrite the loom system-prompt portion of a developer `ResponseItem::Message`.
 *
 * Codex stores the developer message's `content` as an array of input_text
 * items, one per section (permissions / our loom prompt / collaboration_mode
 * / apps_instructions / skills_instructions / ...). We identify our section
 * by its opening line (`# Loom Branch System`) — distinct from Codex's own
 * sections which all open with an `<xxx_instructions>` tag.
 */
function rewriteLoomPromptInDeveloperMessage(
  devMsg: Entry,
  childLoomPrompt: string,
): Entry {
  const copy = structuredClone(devMsg) as any;
  const content = copy?.payload?.content;
  if (!Array.isArray(content)) return copy as Entry;
  copy.payload.content = content.map((item: any) => {
    if (
      item?.type === "input_text" &&
      typeof item.text === "string" &&
      item.text.startsWith(LOOM_PROMPT_ANCHOR)
    ) {
      return { ...item, text: childLoomPrompt };
    }
    return item;
  });
  return copy as Entry;
}

/** Find the (usually single) developer `Message` ResponseItem in parent entries. */
function findDeveloperMessage(entries: Entry[]): Entry | null {
  for (const e of entries) {
    const ea = e as any;
    if (
      ea?.type === "response_item" &&
      ea?.payload?.type === "message" &&
      ea?.payload?.role === "developer"
    ) {
      return e;
    }
  }
  return null;
}

/** Find the `<environment_context>` user `Message` ResponseItem in parent entries. */
function findEnvironmentContextMessage(entries: Entry[]): Entry | null {
  for (const e of entries) {
    const ea = e as any;
    if (
      ea?.type === "response_item" &&
      ea?.payload?.type === "message" &&
      ea?.payload?.role === "user"
    ) {
      const c = ea?.payload?.content;
      if (
        Array.isArray(c) &&
        c[0]?.type === "input_text" &&
        typeof c[0]?.text === "string" &&
        c[0].text.startsWith("<environment_context>")
      ) {
        return e;
      }
    }
  }
  return null;
}

/** Find the latest `turn_context` entry at or before `upToIndex`. */
function findLatestTurnContext(entries: Entry[], upToIndex: number): Entry | null {
  for (let i = Math.min(upToIndex, entries.length - 1); i >= 0; i--) {
    if (entryType(entries[i]) === "turn_context") return entries[i];
  }
  return null;
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
 * Build an 8-entry synthesized child session for `inherit_context=false`.
 *
 * Mirrors the shape of a fresh Codex session's first turn
 * (session_meta → task_started → developer message → env_context user →
 * turn_context → ...turn body... → task_complete), except the "turn body"
 * is a single synthesized fork call + its birth announcement output, with
 * no preceding user input. The child's model sees: "I spontaneously
 * forked myself in my first turn; my next real user input (`[loom] Begin.`)
 * starts the second turn."
 *
 * What's inherited from parent (verbatim or with id/turn_id swapped):
 *   - session_meta  (base_instructions, cwd, originator, cli_version, ...)
 *   - developer message  (permissions / collab_mode / apps / skills sections;
 *                         but the loom-prompt section is re-rendered with
 *                         the child's BRANCH_ID)
 *   - environment_context user message  (cwd/shell/date/tz — parent and
 *                                        child share the cwd)
 *   - latest turn_context  (model, policy, ... — child-swapped turn_id;
 *                           informational only, not sent to model)
 *
 * What's synthesized:
 *   - task_started / task_complete pair for this fake fork turn
 *   - function_call: `mcp__loom__fork` with the user's instruction
 *   - function_call_output: the birth announcement text
 */
function buildInheritFalseSynthesis(opts: {
  parentEntries: Entry[];
  forkIndex: number;
  childAgentSessionId: string;
  childBranchId: string;
  instruction: string;
  cwd: string;
  birthText: string;
}): Entry[] {
  const { parentEntries, forkIndex } = opts;
  const parentSessionMeta = parentEntries[0];
  const parentDevMsg = findDeveloperMessage(parentEntries);
  const parentEnvCtx = findEnvironmentContextMessage(parentEntries);
  const parentTurnCtx = findLatestTurnContext(parentEntries, forkIndex);

  if (!parentDevMsg) {
    throw new Error(
      "buildInheritFalseSynthesis: parent rollout has no developer message — " +
        "cannot construct child system prompt without it",
    );
  }

  const childLoomPrompt = renderSystemPrompt({ branchId: opts.childBranchId });
  const sessionMeta = inheritSessionMeta(parentSessionMeta, opts.childAgentSessionId);
  const developerMsg = rewriteLoomPromptInDeveloperMessage(parentDevMsg, childLoomPrompt);

  const turnId = randomUUID();
  const callId = `call_${randomUUID().replace(/-/g, "").slice(0, 24)}`;
  const now = nowIso();

  const taskStarted: Entry = {
    timestamp: now,
    type: "event_msg",
    payload: {
      type: "task_started",
      turn_id: turnId,
      model_context_window: 0,
      collaboration_mode_kind: "default",
    },
  };

  // env_context: clone parent's (same cwd/shell/tz). Fall back to a bare
  // synthesized one if parent rollout somehow lacks it (defensive).
  const envCtxMsg: Entry = parentEnvCtx
    ? (structuredClone(parentEnvCtx) as Entry)
    : {
        timestamp: now,
        type: "response_item",
        payload: {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: `<environment_context>\n  <cwd>${opts.cwd}</cwd>\n</environment_context>`,
            },
          ],
        },
      };

  // turn_context: clone parent's latest, swap turn_id. If missing, fall
  // back to a minimal one (turn_context isn't sent to the model so this
  // is informational; reconstruct_history_from_rollout reads it to set
  // reference_context_item so `build_initial_context` won't re-run).
  let turnContext: Entry;
  if (parentTurnCtx) {
    const tc = structuredClone(parentTurnCtx) as any;
    tc.timestamp = now;
    if (tc.payload) tc.payload.turn_id = turnId;
    turnContext = tc as Entry;
  } else {
    turnContext = {
      timestamp: now,
      type: "turn_context",
      payload: { turn_id: turnId, cwd: opts.cwd },
    };
  }

  // EventMsg::UserMessage: Codex's reconstruct_history_from_rollout only
  // treats a segment as a "user turn" (and thus captures its turn_context
  // as reference_context_item) when it contains an EventMsg::UserMessage.
  // Without this, the first real user turn on resume would trigger
  // build_initial_context → a duplicate developer message gets written.
  // The event's `message` content is ignored by reconstruction (matched as
  // `UserMessage(_)`) and NOT surfaced to the model (only ResponseItem
  // entries go into the API input) — so an empty string is fine.
  const userMessageEvent: Entry = {
    timestamp: now,
    type: "event_msg",
    payload: {
      type: "user_message",
      message: "",
    },
  };

  const forkCall: Entry = {
    timestamp: now,
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

  return [
    sessionMeta,
    taskStarted,
    developerMsg,
    envCtxMsg,
    turnContext,
    userMessageEvent,
    forkCall,
    forkOut,
    taskComplete,
  ];
}

export function codexBuildChildSessionEntries(
  opts: BuildChildSessionOpts,
): Entry[] {
  if (!opts.inheritContext) {
    return buildInheritFalseSynthesis({
      parentEntries: opts.forkLocation.entries,
      forkIndex: opts.forkLocation.forkIndex,
      childAgentSessionId: opts.childAgentSessionId,
      childBranchId: opts.childBranchId,
      instruction: opts.instruction,
      cwd: opts.cwd,
      birthText: opts.birthAnnouncementText,
    });
  }

  // inheritContext=true: slice parent prefix up to and including the fork
  // call, rewrite session_meta (id + timestamps) and the developer message
  // (so child sees its own BRANCH_ID in the loom system prompt), then
  // append the synthetic function_call_output + task_complete closure.
  const childLoomPrompt = renderSystemPrompt({ branchId: opts.childBranchId });
  const prefix = opts.forkLocation.entries
    .slice(0, opts.forkLocation.forkIndex + 1)
    .map((e, i) => {
      const ea = e as any;
      if (i === 0 && entryType(e) === "session_meta") {
        return inheritSessionMeta(e, opts.childAgentSessionId);
      }
      if (
        ea?.type === "response_item" &&
        ea?.payload?.type === "message" &&
        ea?.payload?.role === "developer"
      ) {
        return rewriteLoomPromptInDeveloperMessage(e, childLoomPrompt);
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
