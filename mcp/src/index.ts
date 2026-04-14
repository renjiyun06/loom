#!/usr/bin/env node
/**
 * Loom MCP server entry point.
 *
 * Launched as a stdio child of each Claude Code instance. The parent CC
 * process sets LOOM_SESSION and LOOM_BRANCH env vars so this server
 * knows which Loom session and branch it's serving.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { forkTool, handleFork } from "./tools/fork.js";
import { sendTool, handleSend } from "./tools/send.js";
import { checkoutTool, handleCheckout } from "./tools/checkout.js";
import { openDb, type Db } from "./db.js";

/**
 * Runtime context shared across tool handlers.
 *
 * Environment variables that identify this MCP server instance are
 * deliberately kept at the Loom layer (`LOOM_SESSION` / `LOOM_BRANCH`).
 * The CC session UUID for this branch is an implementation detail
 * stored in SQLite; handlers fetch it via the database when needed.
 */
export interface Context {
  sessionId: string;  // Loom session id, from LOOM_SESSION env
  branchId: string;   // this instance's branch id, from LOOM_BRANCH env
  db: Db;
}

function readContext(): Context {
  const sessionId = process.env.LOOM_SESSION;
  const branchId = process.env.LOOM_BRANCH;
  if (!sessionId || !branchId) {
    throw new Error(
      "LOOM_SESSION and LOOM_BRANCH environment variables must be set",
    );
  }
  return {
    sessionId,
    branchId,
    db: openDb(),
  };
}

async function main() {
  const ctx = readContext();

  const server = new Server(
    { name: "loom", version: "0.0.1" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [forkTool, sendTool, checkoutTool],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    switch (name) {
      case "fork":
        return handleFork(ctx, args ?? {});
      case "send":
        return handleSend(ctx, args ?? {});
      case "checkout":
        return handleCheckout(ctx, args ?? {});
      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  });

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("[loom-mcp] fatal:", err);
  process.exit(1);
});
