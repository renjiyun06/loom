/**
 * `send` MCP tool — deliver a message to another branch. Auto-starts
 * the target's agent if its tmux session is not live.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Context } from "../server.js";
import { getAdapter } from "../../adapters/factory.js";
import { getBranch, getSession } from "../../core/db.js";
import { sendKeys, sessionExists, tmuxSessionName, newSession } from "../../core/tmux.js";
import {
  sendLockPath,
  sleep,
  withFileLock,
  shellQuote,
} from "../../core/utils.js";
import { renderSystemPrompt } from "../../core/system-prompt.js";

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

  const targetBranch = getBranch(ctx.db, ctx.loomSessionId, target);
  if (!targetBranch) {
    return {
      content: [
        { type: "text", text: `Failed to send: no such branch '${target}'.` },
      ],
      isError: true,
    };
  }
  const session = getSession(ctx.db, ctx.loomSessionId);
  if (!session) {
    throw new Error(
      `send: session ${ctx.loomSessionId} not registered in DB`,
    );
  }

  const tmuxName = tmuxSessionName(ctx.loomSessionId, target);
  if (!sessionExists(tmuxName)) {
    const adapter = getAdapter(targetBranch.agent_type);
    const promptText = renderSystemPrompt({ branchId: target });
    const argv = adapter.buildLaunchCommand({
      agentSessionId: targetBranch.agent_session_id,
      cwd: session.cwd,
      loomSessionId: ctx.loomSessionId,
      branchId: target,
      systemPromptText: promptText,
      resume: true,
    });
    newSession({
      name: tmuxName,
      cwd: session.cwd,
      command: argv.map(shellQuote).join(" "),
      env: {
        LOOM_SESSION: ctx.loomSessionId,
        LOOM_BRANCH: target,
      },
    });
    await sleep(10_000);
  }

  const line = `[loom: from branch ${ctx.branchId}] ${content}`;
  await withFileLock(sendLockPath(tmuxName), () => {
    sendKeys(tmuxName, line);
  });

  return { content: [{ type: "text", text: "Message sent." }] };
}
