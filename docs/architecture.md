# Loom Architecture

This document is a maintenance map for Loom's current implementation. It
describes what each layer owns, how the main execution paths move through
the system, and which boundaries should stay intact as the code evolves.

Loom is a local coordination layer. It starts one terminal agent process
per branch, gives each process the same MCP tools, and stores only enough
metadata to relaunch branches and understand the branch tree. Claude Code
and Codex remain the owners of their own transcript/session files.

## Layer Map

```text
agent TUI
  |
  | MCP stdio + hook payloads
  v
src/mcp/* and src/hooks/*
  |
  | DB rows, pending-fork files, tmux operations
  v
src/core/*
  |
  | agent-specific session files, launch flags, hook parsing
  v
src/adapters/*
```

| Layer | Main paths | Responsibility |
| --- | --- | --- |
| CLI | `src/cli/*` | User-facing commands such as `new`, `list`, `attach`, `relaunch`, `stop`, and `rm`. The CLI validates prerequisites, creates sessions, manages tmux attachment, and delegates relaunch work to core helpers. |
| MCP server/tools | `src/mcp/server.ts`, `src/mcp/tools/*` | The stdio MCP server exposed to each agent. It reads `LOOM_SESSION` and `LOOM_BRANCH`, opens the SQLite database, and currently registers `fork` and `send`. `checkout.ts` exists as a stub source file but is not registered by the MCP server. |
| Core orchestration | `src/core/*` | Agent-neutral orchestration: SQLite access, tmux operations, fork execution, launch-script generation, pending-fork files, locks, and system-prompt rendering. |
| Adapters | `src/adapters/*` | The boundary around agent-specific behavior: native session file paths and JSONL shapes, launch argv, global hook/MCP config, hook payload parsing, fork-call lookup, and child session synthesis. |
| Hooks | `src/hooks/*`, `src/core/hook-runner.ts` | Small agent-specific entry points that feed payloads into the shared hook runner. Hooks are the bridge from "agent has flushed a turn" to "Loom can execute pending fork work." |
| Runtime state | `~/.loom/*`, agent-native session files, tmux sessions | Local state needed to track sessions, branches, pending forks, locks, launch scripts, and live agent processes. Loom does not store complete conversations. |

## Main Session Creation

`loom new` is implemented in `src/cli/cmd-new.ts`.

1. CLI preflight checks require the built `dist/` files, `tmux`,
   `sqlite3`, and the selected agent binary.
2. The selected `AgentAdapter` writes idempotent global configuration:
   Claude Code config under `~/.loom/`, or Codex MCP/hook config under
   `~/.codex/`.
3. Loom allocates a short Loom session id, an agent session id hint, and
   creates the `main` branch row in SQLite.
4. The adapter builds the fresh-launch argv with the rendered branch
   system prompt.
5. Core writes a per-branch launch script under `~/.loom/` and starts a
   tmux session named `loom-<session>-main` with `LOOM_SESSION` and
   `LOOM_BRANCH=main`.
6. Loom asks the adapter to discover the real native agent session id.
   Claude Code uses the hint passed by Loom. Codex may choose its own
   rollout id, so the adapter watches `~/.codex/sessions/` and the DB row
   is updated if the discovered id differs.
7. The CLI attaches the user's terminal to the tmux session.

## Fork Flow

The `fork` tool has two phases because the parent agent's native session
file is not necessarily flushed when the MCP tool handler returns.

```text
agent calls fork
  |
  v
src/mcp/tools/fork.ts
  - validate instruction
  - read current branch from SQLite
  - allocate child branch id and child agent session id
  - insert child branch row
  - write ~/.loom/pending-forks/<parent-agent-session-id>.json
  - return "Branch <id> created."
  |
  v
agent finishes/flushed turn
  |
  v
agent hook fires
  |
  v
src/core/hook-runner.ts
  - parse hook payload through the adapter
  - ignore non-fork hook firings
  - consume pending-fork file
  - call executeFork(...)
  |
  v
src/core/execute-fork.ts
  - wait for the fork call in the parent native session file
  - synthesize the child native session file through the adapter
  - start child tmux session
  - send "[loom] Begin." kickoff
```

The MCP handler deliberately does not synthesize or launch the child
itself. It only records durable intent. The hook phase runs after the
agent has written the fork call into its native session file, which lets
the adapter build an accurate child history.

`executeFork` is agent-neutral except for adapter calls. It uses the
parent adapter to locate the fork call, rejects cross-agent forks, uses
the child adapter to build and write session entries, then starts the
child with `resume: true` in a new tmux session named
`loom-<session>-<child-branch>`.

For `inherit_context=true`, the adapter copies the parent conversation
prefix through the fork call and appends a synthetic birth result. For
`inherit_context=false`, the adapter creates a minimal native session
that still contains enough metadata and instruction context for the
child agent to resume correctly.

## Send Flow

`send` is implemented in `src/mcp/tools/send.ts`.

1. The MCP handler validates `target` and `content`.
2. It looks up the target branch and Loom session in SQLite.
3. If the target tmux session is not alive, it rebuilds a resume launch
   command through the target branch's adapter, writes a launch script,
   starts tmux, and waits briefly for the TUI to come up.
4. It prefixes the message as
   `[loom: from branch <source>] <content>`.
5. It serializes delivery with a `~/.loom/send-locks/` file lock and
   injects the line plus Enter into the target tmux pane.

`send` is process-level message injection. It does not edit the target
branch's native session file directly; the receiving agent records the
message through its normal TUI/runtime path.

## Adapter Boundary

The `AgentAdapter` interface is defined in `src/adapters/types.ts`.

Keep these concerns in core:

- Loom session and branch identity.
- SQLite schema and query helpers.
- Tmux session naming, creation, killing, and text injection.
- Pending-fork and send-lock files.
- The high-level order of `new`, `fork`, `executeFork`, `send`, and
  relaunch flows.
- Cross-agent policy. Today `executeFork` rejects a fork when parent and
  child agent types differ.

Keep these concerns in adapters:

- Native session file path discovery.
- Native JSONL/rollout parsing and writing.
- How to find a fork call after a hook fires.
- How to synthesize child session entries for inherited and isolated
  forks.
- Agent launch flags and resume/fresh-session semantics.
- Global MCP/hook configuration.
- Hook payload parsing.
- Discovering a newly created native session id after `loom new`.

Claude Code and Codex differ in ways that should not leak into core:

- Claude Code stores project-scoped JSONL files under
  `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`; Codex stores
  dated rollout files under `~/.codex/sessions/YYYY/MM/DD/...`.
- Claude Code accepts Loom's session id hint on launch; Codex may choose
  a rollout id that Loom discovers after startup.
- Claude Code gets the branch prompt through `--append-system-prompt`;
  Codex gets it through `developer_instructions` on fresh launches and
  through the synthesized rollout on resumed fork children.
- Claude Code uses a `PostToolUse` hook filtered for fork calls; Codex
  uses a `Stop` hook and relies on the pending-fork file as the final
  filter.
- Claude Code and Codex encode tool calls, tool results, session ids, and
  turn closure differently in their native files.

## Persistence And Runtime State

### SQLite

`src/core/db.ts` owns `~/.loom/loom.db`. The current schema version is
tracked with `PRAGMA user_version` and stores:

- `sessions`: Loom session id, working directory, and creation time.
- `branches`: branch id, parent branch id, agent type, native agent
  session id, fork instruction, inherit flag, and creation time.

SQLite is the source of truth for the branch tree and relaunch metadata.
It is not a transcript store.

### Tmux

`src/core/tmux.ts` names branch processes as
`loom-<session>-<branch>`. Tmux is responsible for:

- isolating each branch in its own process and pane;
- keeping a branch alive after the user detaches;
- accepting injected messages from `send` and fork kickoff.

If tmux dies but the DB row remains, `attach`, `relaunch`, and `send`
can start the branch again from the recorded native agent session id.

### Agent-Native Session Files

Claude Code and Codex own their complete conversation files. Loom reads
and writes those files only where needed to create a child branch:

- locate the parent fork call;
- copy or synthesize the child prefix;
- rewrite agent-native session metadata so resume starts the child.

After launch, the agent runtime continues appending to its own file.
Loom does not maintain a second full copy of the conversation.

### Files Under `~/.loom/`

The main Loom-owned files are:

- `loom.db`: SQLite branch/session metadata.
- `pending-forks/`: JSON fork jobs written by `fork` and consumed by
  hooks.
- `send-locks/`: file locks that serialize tmux message injection per
  target.
- `debug.log`: best-effort hook diagnostics.
- `mcp-config.json` and `settings.json`: Claude Code MCP and hook
  configuration.
- `session-<session>-<branch>-launch.sh`: generated launch scripts used
  by tmux.

Codex-specific global config is written under `~/.codex/`, including the
MCP registration and `hooks.json`.

## Current Limits And Non-Goals

- Cross-agent fork is not supported. `fork` always assigns the child the
  parent's agent type, and `executeFork` rejects mismatched parent/child
  agent types.
- The MCP server currently exposes `fork` and `send`. `checkout.ts` is a
  source-level stub for a future frontend signal and has no data-layer
  effect.
- Loom does not merge code, resolve file conflicts, schedule jobs, or
  provide remote orchestration.
- Loom does not store full conversation content in SQLite. Native agent
  transcript files remain the transcript authority.
- The runtime is local and process-oriented. Durable state is enough to
  relaunch registered branches, not to reconstruct an agent session if
  the native agent files are deleted or corrupted.

Future evolution points include cross-agent fork, a first-party checkout
surface, richer branch inspection, and more robust recovery flows. Those
should extend the adapter and core boundaries above rather than mixing
agent-native file semantics into the MCP or CLI layers.
