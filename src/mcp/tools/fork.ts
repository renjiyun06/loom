/**
 * `fork` MCP tool — allocate a child branch, persist it, and write the
 * pending-fork record. The actual child session file synthesis and
 * launch happen in the hook (CC PostToolUse / Codex Stop), because
 * only at hook time is the parent's fork call guaranteed to be on disk.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Context } from "../server.js";
import { getAdapter } from "../../adapters/factory.js";
import {
  getBranch,
  getSession,
  insertBranch,
} from "../../core/db.js";
import { writePendingFork } from "../../core/pending-fork.js";
import { randomHex, nowMs } from "../../core/utils.js";
import type { AgentType, ForkJob } from "../../types.js";

export const forkTool: Tool = {
  name: "fork",
  description:
    "Create a new child branch and start a new agent instance on it, " +
    "running in parallel. You remain on your current branch. Use this " +
    "to spawn a parallel sub-task.",
  inputSchema: {
    type: "object",
    properties: {
      instruction: {
        type: "string",
        description:
          "The task for the new child agent. Visible on the child's " +
          "history as part of this fork call and used to drive it to " +
          "start work.",
      },
      inherit_context: {
        type: "boolean",
        description:
          "Whether the child inherits your current branch's conversation " +
          "history up to this fork call. Default: true. Set false for " +
          "delegation of isolated tasks.",
        default: true,
      },
    },
    required: ["instruction"],
  },
};

export async function handleFork(
  ctx: Context,
  args: Record<string, unknown>,
): Promise<{ content: { type: "text"; text: string }[] }> {
  const instruction = String(args.instruction ?? "");
  const inheritContext =
    args.inherit_context === undefined ? true : Boolean(args.inherit_context);
  if (!instruction) {
    throw new Error("fork: `instruction` is required");
  }

  const parentBranch = getBranch(ctx.db, ctx.loomSessionId, ctx.branchId);
  if (!parentBranch) {
    throw new Error(
      `fork: current branch ${ctx.branchId} not registered in DB`,
    );
  }
  const session = getSession(ctx.db, ctx.loomSessionId);
  if (!session) {
    throw new Error(
      `fork: session ${ctx.loomSessionId} not registered in DB`,
    );
  }

  // MVP: child inherits parent's agent type. Future: allow override via
  // an `agent` arg; interface placeholder below.
  const childAgentType: AgentType = parentBranch.agent_type;
  const childAdapter = getAdapter(childAgentType);
  const childBranchId = randomHex(4);
  const childAgentSessionId = childAdapter.generateSessionId();

  insertBranch(ctx.db, {
    session_id: ctx.loomSessionId,
    branch_id: childBranchId,
    agent_type: childAgentType,
    agent_session_id: childAgentSessionId,
    parent_branch_id: ctx.branchId,
    instruction,
    inherit_context: inheritContext ? 1 : 0,
    created_at: nowMs(),
  });

  const job: ForkJob = {
    loomSessionId: ctx.loomSessionId,
    parentBranchId: ctx.branchId,
    parentAgentSessionId: parentBranch.agent_session_id,
    parentAgentType: parentBranch.agent_type,
    childBranchId,
    childAgentSessionId,
    childAgentType,
    instruction,
    inheritContext,
  };
  writePendingFork(parentBranch.agent_session_id, job);

  return {
    content: [{ type: "text", text: `Branch ${childBranchId} created.` }],
  };
}
