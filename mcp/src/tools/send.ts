/**
 * `send` tool — deliver a message to another branch.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Context } from "../index.js";
import { getBranch, getSession } from "../db.js";
import { launchCc } from "../launcher.js";
import { sendKeys, sessionExists, tmuxSessionName } from "../tmux.js";
import { sendLockPath, sleep, withFileLock } from "../utils.js";

export const sendTool: Tool = {
  name: "send",
  description:
    "Send a message to another branch. If the target branch does not " +
    "currently have an active agent, Loom will start one so the message " +
    "is delivered. You remain on your current branch.",
  inputSchema: {
    type: "object",
    properties: {
      target: {
        type: "string",
        description:
          "The branch id of the recipient (e.g. `main` or a short hex id).",
      },
      content: {
        type: "string",
        description: "The message content.",
      },
    },
    required: ["target", "content"],
  },
};

export async function handleSend(
  ctx: Context,
  args: Record<string, unknown>,
): Promise<{
  content: { type: "text"; text: string }[];
  isError?: boolean;
}> {
  const target = String(args.target ?? "");
  const content = String(args.content ?? "");

  if (!target) {
    return {
      content: [{ type: "text", text: "Failed to send: `target` is required." }],
      isError: true,
    };
  }
  if (!content) {
    return {
      content: [{ type: "text", text: "Failed to send: `content` is required." }],
      isError: true,
    };
  }

  // 1. Look up target branch and session.
  const targetBranch = getBranch(ctx.db, ctx.sessionId, target);
  if (!targetBranch) {
    return {
      content: [
        { type: "text", text: `Failed to send: no such branch '${target}'.` },
      ],
      isError: true,
    };
  }
  const session = getSession(ctx.db, ctx.sessionId);
  if (!session) {
    throw new Error(`send: session ${ctx.sessionId} not registered in database`);
  }

  // 2. Auto-start the target agent if its tmux session is not running.
  const tmuxName = tmuxSessionName(ctx.sessionId, target);
  if (!sessionExists(tmuxName)) {
    launchCc({
      sessionId: ctx.sessionId,
      branchId: target,
      ccSessionId: targetBranch.cc_session_id,
      cwd: session.cwd,
    });
    // Give CC a moment to come up before we inject anything.
    await sleep(10000);
  }

  // 3. Inject the message, serialized per-target against other senders.
  const line = `[loom: from branch ${ctx.branchId}] ${content}`;
  await withFileLock(sendLockPath(tmuxName), () => {
    sendKeys(tmuxName, line);
  });

  return { content: [{ type: "text", text: "Message sent." }] };
}
