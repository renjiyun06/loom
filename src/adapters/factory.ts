/**
 * Adapter registry. Upper layers call `getAdapter(type)` instead of
 * importing concrete adapter classes directly.
 */

import type { AgentType } from "../types.js";
import type { AgentAdapter } from "./types.js";
import { CcAdapter } from "./claude-code/index.js";
import { CodexAdapter } from "./codex/index.js";

export function getAdapter(agentType: AgentType): AgentAdapter {
  switch (agentType) {
    case "claude-code":
      return new CcAdapter();
    case "codex":
      return new CodexAdapter();
    default: {
      const exhaustive: never = agentType;
      throw new Error(`Unknown agent type: ${exhaustive}`);
    }
  }
}
