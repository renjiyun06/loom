/**
 * `fork` tool — create a new child branch.
 *
 * This MCP handler is intentionally minimal: it only allocates the new
 * ids, records the branch in SQLite, and writes a "pending fork" file
 * that the PostToolUse hook will pick up. The actual projection build
 * and child CC launch happen in the hook (see `hooks/post-fork.ts`),
 * because only at hook time is the parent's fork tool_use guaranteed
 * to be on disk.
 */

import { mkdirSync, writeFileSync } from "node:fs";

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Context } from "../index.js";
import { getBranch, getSession, insertBranch } from "../db.js";
import { generateBranchId, generateCcSessionId } from "../jsonl.js";
import type { ForkJob } from "../fork-impl.js";
import { PENDING_FORKS_DIR, pendingForkPath } from "../utils.js";

export const forkTool: Tool = {
  name: "fork",
  description:
    "Create a new child branch and start a new Claude Code instance on " +
    "it, running in parallel. You remain on your current branch. Use " +
    "this to spawn a parallel sub-task.",
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

  // Look up current branch and session.
  const parentBranch = getBranch(ctx.db, ctx.sessionId, ctx.branchId);
  if (!parentBranch) {
    throw new Error(
      `fork: current branch ${ctx.branchId} not registered in database`,
    );
  }
  const session = getSession(ctx.db, ctx.sessionId);
  if (!session) {
    throw new Error(`fork: session ${ctx.sessionId} not registered in database`);
  }

  // Allocate child ids.
  const childBranchId = generateBranchId();
  const childCcSessionId = generateCcSessionId();

  // Register the new branch in SQLite so send/checkout can already see it.
  insertBranch(ctx.db, {
    session_id: ctx.sessionId,
    branch_id: childBranchId,
    cc_session_id: childCcSessionId,
    parent_branch_id: ctx.branchId,
    instruction,
    created_at: Date.now(),
  });

  // Write the pending fork job for the PostToolUse hook to pick up.
  const job: ForkJob = {
    sessionId: ctx.sessionId,
    parentBranchId: ctx.branchId,
    parentCcSessionId: parentBranch.cc_session_id,
    childBranchId,
    childCcSessionId,
    instruction,
    inheritContext,
  };
  mkdirSync(PENDING_FORKS_DIR, { recursive: true });
  writeFileSync(
    pendingForkPath(parentBranch.cc_session_id),
    JSON.stringify(job, null, 2),
  );

  // Return immediately. The hook will do the heavy lifting once the
  // parent's fork tool_use is on disk.
  return {
    content: [{ type: "text", text: `Branch ${childBranchId} created.` }],
  };
}
