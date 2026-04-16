/**
 * Parse the PostToolUse hook payload as delivered by Claude Code on
 * stdin. Field names below match CC's observed payload shape:
 *   { session_id, tool_name, tool_input, tool_response, tool_use_id }
 */

import type { HookTriggerInfo } from "../types.js";

function isForkToolName(name: unknown): boolean {
  if (typeof name !== "string") return false;
  return name === "fork" || /(^|__)fork$/.test(name);
}

export function ccParseHookPayload(rawPayload: string): HookTriggerInfo {
  let payload: any;
  try {
    payload = JSON.parse(rawPayload);
  } catch {
    return { agentSessionId: "", triggerHint: "", mayBeFork: false };
  }
  const agentSessionId: string = String(payload?.session_id ?? "");
  const triggerHint: string = String(payload?.tool_use_id ?? "");
  const mayBeFork = isForkToolName(payload?.tool_name);
  return { agentSessionId, triggerHint, mayBeFork };
}
