/**
 * Adapter interface hiding agent-specific operations behind one facade.
 *
 * Upper layers (`src/cli/*`, `src/core/execute-fork`, `src/core/hook-runner`,
 * `src/mcp/tools/*`) look up the right Adapter via `src/adapters/factory.ts`
 * and never reference a concrete agent directly.
 */

import type { AgentType } from "../types.js";

/** Opaque per-line record from an agent's session JSONL/rollout file. */
export type Entry = Record<string, unknown>;

/** Result of locating the fork tool call in a parent session file. */
export interface ForkLocation {
  /** All parent entries up to and including the fork-call entry. */
  entries: Entry[];
  /** Index in `entries` of the fork-call entry. */
  forkIndex: number;
  /** Agent-native call id (CC: tool_use_id; Codex: call_id). */
  callId: string;
  /**
   * Codex-only: turn_id surrounding the fork call. Used when
   * synthesizing the child's closing `task_complete` entry. CC sets
   * undefined.
   */
  turnId?: string;
}

export interface BuildChildSessionOpts {
  forkLocation: ForkLocation;
  childAgentSessionId: string;
  parentBranchId: string;
  childBranchId: string;
  inheritContext: boolean;
  /** Instruction passed to fork (used when inheritContext=false). */
  instruction: string;
  /** Working directory of the loom session (embedded in some entries). */
  cwd: string;
  /**
   * Plain-text birth announcement loom wants the child to see as the
   * fork tool's return value. Adapter wraps it in agent-native shape.
   */
  birthAnnouncementText: string;
}

export interface LaunchCommandOpts {
  /** Agent-side session id. Main branch: fresh id; fork children: the
   *  child's id written into the child rollout/JSONL. */
  agentSessionId: string;
  cwd: string;
  loomSessionId: string;
  branchId: string;
  /** Rendered system-prompt text with `{{BRANCH_ID}}` already substituted. */
  systemPromptText: string;
  /** true → use the agent's "resume" flag; false → launch a fresh session. */
  resume: boolean;
}

export interface EnsureGlobalConfigOpts {
  /** Absolute path to compiled dist/mcp/server.js (the loom MCP entry). */
  mcpServerPath: string;
  /** Absolute path to compiled dist/hooks/<this agent's hook>.js. */
  hookScriptPath: string;
}

export interface HookTriggerInfo {
  /** Agent session id carried in the hook payload; used to look up
   *  pending-fork and the corresponding branch row. */
  agentSessionId: string;
  /** triggerHint fed to waitForForkCall. CC: tool_use_id; Codex: turn_id. */
  triggerHint: string;
  /**
   * Whether this hook firing *might* correspond to a fork call. If
   * false the runner short-circuits without touching the DB.
   *
   * - CC: true when tool_name ends with "fork".
   * - Codex: always true (Stop fires per turn, the pending-fork file
   *   existence is the real filter).
   */
  mayBeFork: boolean;
}

export interface AgentAdapter {
  readonly agentType: AgentType;

  /** Produce a fresh session id the agent will accept on resume. */
  generateSessionId(): string;

  /** Compute the absolute session file path for a (cwd, sessionId). */
  sessionFilePath(cwd: string, agentSessionId: string): string;

  readEntries(path: string): Entry[];
  writeEntries(path: string, entries: Entry[]): void;

  /**
   * Wait until the fork tool call corresponding to `triggerHint`
   * appears in the parent's session file. Must tolerate files still
   * being flushed when the hook first fires.
   */
  waitForForkCall(
    parentFile: string,
    triggerHint: string,
    options?: { timeoutMs?: number; pollIntervalMs?: number },
  ): Promise<ForkLocation>;

  /**
   * Build the child session's entry list. For inheritContext=true:
   * parent prefix (with any necessary rewrites) + birth announcement +
   * agent-specific closure. For inheritContext=false: a minimal
   * synthetic session consisting of a synthetic fork call + birth
   * announcement + closure.
   */
  buildChildSessionEntries(opts: BuildChildSessionOpts): Entry[];

  /** Build the argv to spawn this agent. */
  buildLaunchCommand(opts: LaunchCommandOpts): string[];

  /**
   * One-time, idempotent global configuration. Writes whatever files
   * this agent needs for hooks/MCP/feature flags to function.
   */
  ensureGlobalConfig(opts: EnsureGlobalConfigOpts): void;

  /** Parse the raw hook-payload JSON into the info the hook-runner needs. */
  parseHookPayload(rawPayload: string): HookTriggerInfo;
}
