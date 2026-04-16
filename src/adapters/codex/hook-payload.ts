/**
 * Parse the Stop hook payload delivered by Codex on stdin. Observed
 * fields include session_id, turn_id, transcript_path, cwd,
 * hook_event_name, model, last_assistant_message, stop_hook_active.
 */

import type { HookTriggerInfo } from "../types.js";

export function codexParseHookPayload(rawPayload: string): HookTriggerInfo {
  let payload: any;
  try {
    payload = JSON.parse(rawPayload);
  } catch {
    return { agentSessionId: "", triggerHint: "", mayBeFork: false };
  }
  const agentSessionId: string = String(payload?.session_id ?? "");
  const triggerHint: string = String(payload?.turn_id ?? "");
  // Codex Stop fires every turn; the pending-fork file is the real
  // filter, so we set mayBeFork=true unconditionally.
  return { agentSessionId, triggerHint, mayBeFork: true };
}
