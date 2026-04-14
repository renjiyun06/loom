/**
 * `checkout` tool — request the user's frontend to switch focus to another
 * branch. Pure interface-level action; does not affect any branch's data.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import type { Context } from "../index.js";

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
  ctx: Context,
  args: Record<string, unknown>,
): Promise<{ content: { type: "text"; text: string }[] }> {
  // TODO (MVP stage):
  //   - There is no frontend yet. For now just validate the target exists
  //     in SQLite and return a short confirmation.
  //   - Later: publish a `focus_requested` event on the control channel
  //     for any connected frontend to pick up.

  throw new Error("checkout: not implemented");
}
