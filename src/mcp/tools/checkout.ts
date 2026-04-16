/**
 * `checkout` MCP tool — request the user's frontend to switch focus.
 * Pure interface-level; has no data-layer effect.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Context } from "../server.js";

export const checkoutTool: Tool = {
  name: "checkout",
  description:
    "Ask the user's frontend to switch its focus view to another branch. " +
    "This has no data-layer effect and does not move you.",
  inputSchema: {
    type: "object",
    properties: {
      target: {
        type: "string",
        description:
          "The branch id whose view should become active in the user's " +
          "frontend (e.g. `main` or a short hex id).",
      },
    },
    required: ["target"],
  },
};

export async function handleCheckout(
  _ctx: Context,
  _args: Record<string, unknown>,
): Promise<{ content: { type: "text"; text: string }[] }> {
  // No frontend event bus yet; keep as a stub that acknowledges.
  return {
    content: [
      {
        type: "text",
        text:
          "checkout acknowledged (no frontend registered to act on the request yet).",
      },
    ],
  };
}
