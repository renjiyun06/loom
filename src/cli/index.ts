#!/usr/bin/env node
/**
 * loom — parallel branching for Claude Code and Codex.
 */

import type { AgentType } from "../types.js";
import { cmdNew } from "./cmd-new.js";
import { cmdList } from "./cmd-list.js";
import { cmdAttach } from "./cmd-attach.js";
import { cmdStop } from "./cmd-stop.js";
import { cmdRm } from "./cmd-rm.js";

const USAGE = `\
Usage: loom [COMMAND] [ARGS]

Commands:
  new [--agent <type>]       Start a new Loom session on a main branch.
                             --agent defaults to claude-code.
                             Valid types: claude-code, codex.
                             (Default command when none is given.)
  list                       Show all sessions and their branch trees.
  attach <session> [branch]  Attach to a branch's tmux. If the tmux
                             session isn't alive but the branch is
                             registered, relaunches the agent first.
                             Default branch is 'main'.
  stop <session> [branch]    Kill tmux session(s) for a Loom session.
                             Without branch: kill every live branch
                             of that session. DB rows preserved;
                             'loom attach' can relaunch.
  rm <session> [branch] [-f] Permanently remove a session (or a branch
                             and its descendants) from Loom's records.
                             Agent session files are left untouched.
                             '-f' skips the confirmation prompt.
  help, --help, -h           Show this help.

Paths:
  DB       ~/.loom/loom.db
  Config   ~/.loom/mcp-config.json (CC), ~/.codex/hooks.json (Codex)
`;

function coerceAgent(v: string | undefined): AgentType {
  const s = (v ?? "claude-code").trim();
  if (s === "claude-code" || s === "cc") return "claude-code";
  if (s === "codex") return "codex";
  console.error(`loom: invalid --agent '${v}'. use claude-code or codex.`);
  process.exit(2);
}

function parseNewOpts(args: string[]): { agent: AgentType } {
  let agent: string | undefined;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--agent") {
      agent = args[++i];
    } else if (a.startsWith("--agent=")) {
      agent = a.slice("--agent=".length);
    } else {
      console.error(`loom: unknown argument '${a}'`);
      process.exit(2);
    }
  }
  return { agent: coerceAgent(agent) };
}

function parseRmArgs(args: string[]): {
  sessionId: string;
  branch?: string;
  force: boolean;
} {
  let force = false;
  const positional: string[] = [];
  for (const a of args) {
    if (a === "-f" || a === "--force") force = true;
    else positional.push(a);
  }
  if (!positional[0]) {
    console.error(`loom: rm requires a session id`);
    console.error(`      loom rm <session> [branch] [-f]`);
    process.exit(2);
  }
  return { sessionId: positional[0], branch: positional[1], force };
}

function main(argv: string[]): void {
  const [cmd, ...rest] = argv;
  switch (cmd ?? "new") {
    case undefined:
    case "new": {
      const opts = parseNewOpts(rest);
      cmdNew(opts);
      return;
    }
    case "list":
      cmdList();
      return;
    case "attach": {
      if (!rest[0]) {
        console.error(`loom: attach requires a session id`);
        console.error(`      loom attach <session> [branch]`);
        process.exit(2);
      }
      cmdAttach(rest[0], rest[1]);
      return;
    }
    case "stop": {
      if (!rest[0]) {
        console.error(`loom: stop requires a session id`);
        console.error(`      loom stop <session> [branch]`);
        process.exit(2);
      }
      cmdStop(rest[0], rest[1]);
      return;
    }
    case "rm": {
      const { sessionId, branch, force } = parseRmArgs(rest);
      cmdRm(sessionId, branch, { force });
      return;
    }
    case "help":
    case "--help":
    case "-h":
      process.stdout.write(USAGE);
      return;
    default:
      console.error(`loom: unknown command '${cmd}'`);
      console.error(`      run 'loom --help' for usage`);
      process.exit(2);
  }
}

main(process.argv.slice(2));
