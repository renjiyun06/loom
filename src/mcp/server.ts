#!/usr/bin/env node
/**
 * Loom MCP server entry. One binary, shared by all agents.
 *
 * Launched as a stdio child of each Claude Code / Codex instance. The
 * parent agent passes LOOM_SESSION and LOOM_BRANCH through environment
 * variables (CC: inherited from tmux; Codex: injected via `-c
 * mcp_servers.loom.env=...`).
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

import { forkTool, handleFork } from "./tools/fork.js";
import { sendTool, handleSend } from "./tools/send.js";
import { openDb, type Db } from "../core/db.js";

export interface Context {
  loomSessionId: string;
  branchId: string;
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
  return { loomSessionId: sessionId, branchId, db: openDb() };
}

async function main(): Promise<void> {
  const ctx = readContext();
  const server = new Server(
    { name: "loom", version: "0.1.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [forkTool, sendTool],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;
    switch (name) {
      case "fork":
        return handleFork(ctx, args ?? {});
      case "send":
        return handleSend(ctx, args ?? {});
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
