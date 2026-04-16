/**
 * Shared domain types used across Loom modules.
 */

export type AgentType = "claude-code" | "codex";

export interface Session {
  id: string;
  cwd: string;
  created_at: number;
}

export interface Branch {
  session_id: string;
  branch_id: string;
  agent_type: AgentType;
  agent_session_id: string;
  parent_branch_id: string | null;
  instruction: string | null;
  inherit_context: 0 | 1 | null;
  created_at: number;
}

/**
 * The "pending fork" record — written by the MCP fork handler and picked
 * up by the post-hook to do the heavy lifting. Serialized to JSON on
 * disk at ~/.loom/pending-forks/<parent-agent-session-id>.json.
 */
export interface ForkJob {
  loomSessionId: string;
  parentBranchId: string;
  parentAgentSessionId: string;
  parentAgentType: AgentType;
  childBranchId: string;
  childAgentSessionId: string;
  childAgentType: AgentType;
  instruction: string;
  inheritContext: boolean;
}
