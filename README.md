# Loom

> Parallel branching system for **Claude Code and Codex** — turn a
> single-threaded conversation into a forkable, parallel, and
> message-passing tree.

## What & Why

A normal agent session is linear: you and the agent walk down one
thread of context together. If you want to explore a side question, you
either start a fresh session (losing context) or rewind (losing what
came after). Neither composes well with the way real work branches.

Loom answers this with three primitives:

- **`fork`** — spawn a new branch with its own agent instance running
  in parallel. The child inherits the conversation up to the fork
  point; you keep working on the parent.
- **`send`** — deliver a message to another branch. Use it to ask a
  question, hand off a sub-task, or report a result back.
- **`checkout`** — ask the user's frontend to switch focus to another
  branch. Pure view-layer; no data effect.

Branches are full agent instances, not "thoughts" or "rewinds". They
actually run, in their own tmux sessions, in parallel, and share
exactly the prefix of history that existed at the moment of fork.

## Supported agents

- **Claude Code** — session JSONL under `~/.claude/projects/...`,
  triggered via `PostToolUse` hook.
- **Codex** (OpenAI Codex CLI v0.120+) — rollout JSONL under
  `~/.codex/sessions/YYYY/MM/DD/...`, triggered via `Stop` hook
  (requires `codex features enable codex_hooks`).

Each branch pins its agent type; fork children default to the same
agent as the parent. You can mix agents across a session's branches in
principle, but cross-agent fork (parent CC, child Codex) is not yet
supported — the child inherits the parent's agent.

## How it works

```
Branch main (agent=codex)
 ├─ user: "Refactor the auth module"
 ├─ assistant: [fork "Explore current auth structure"]   ──┐
 │                                                          │
 │                            Branch 7b2e1c4d (parallel)    │
 │                             ├─ ... reads code ...        │
 │                             ├─ ... explores ...          │
 │                             └─ [send → main: "Auth uses  │
 │                                  JWT + middleware chain  │
 │                                  X → Y → Z"]             │
 │                                                          │
 ├─ assistant: "Meanwhile let me draft the refactor goals" ─┘
 ├─ [from 7b2e1c4d] Auth uses JWT + middleware chain X → Y → Z
 └─ assistant: "Good. Based on that, here's the plan..."
```

**`fork`** allocates a new branch id, synthesizes a child session file
by copying the parent's history up to (and including) the fork call,
injects a "birth announcement" as the fork's tool result, then launches
a fresh agent instance on that file inside a new tmux session.

**`send`** writes a `[loom: from branch <id>] ...` line into the
target branch's tmux. If the target's agent is dormant, it gets started
on demand. The receiver sees the message as a normal user turn.

**`checkout`** is a thin signal to the user's frontend (e.g. a web GUI
watching loom's tmux sessions) to switch focus to a given branch.
It does not move the caller and does not modify any branch's history.

## Quick start

**Prerequisites**
- `tmux`, `node` (≥ 22), `sqlite3`
- At least one of: [Claude Code](https://docs.claude.com/claude-code)
  (the `claude` CLI), [Codex CLI](https://developers.openai.com/codex/cli)
  (the `codex` CLI)

**Install**

```bash
git clone https://github.com/renjiyun06/loom.git
cd loom
npm install
npm run build
npm link                     # makes `loom` available on PATH
```

**Use**

```bash
# Start a new Loom session running Claude Code on the main branch (default)
loom new
loom new --agent claude-code  # same thing, explicit

# Or start a new session running Codex
loom new --agent codex

# Inside the agent, call the `fork` tool to spawn a parallel branch:
#   fork(instruction: "Investigate X and report back", inherit_context: true)
# A new tmux session 'loom-<sid>-<branch>' starts in the background.

# In another terminal, see the tree:
loom list

# Attach to any branch's tmux to watch or interact:
loom attach <session-id> <branch-id>
```

Detach a tmux session with `Ctrl-B d`. Use `loom stop <session>` to
kill all live tmux sessions of a Loom session — the branches stay
registered in the DB and `loom attach` will relaunch them.

## CLI reference

| Command | What it does |
|---------|--------------|
| `loom new [--agent <type>]` | Start a new Loom session on a fresh `main` branch. Agent is `claude-code` (default) or `codex`. |
| `loom list [--json]` | Print all sessions and their branch trees, marking agent, alive/dead, and inherit/isolated. With `--json`, emit a flat machine-readable forest document (`{sessions:[{id,cwd,created_at,branches:[{id,parent_id,agent_type,agent_session_id,inherit_context,instruction,alive,tmux_name,created_at}]}]}`) — branches are a flat array per session with `parent_id` references; `instruction` is never truncated. Intended for tooling (VS Code extension, dashboards). |
| `loom attach <session> [branch]` | Attach to a branch's tmux. Relaunches the agent if the tmux is dead but the branch is registered. Default branch: `main`. |
| `loom relaunch <session> [branch]` | Ensure a branch's tmux is alive WITHOUT attaching. Prints `already-alive: <name>` or `launched: <name>`. Intended for tooling (Agentboard, VS Code extension). Default branch: `main`. |
| `loom stop <session> [branch]` | Kill tmux for a session (or one of its branches). DB registrations are preserved. |
| `loom rm <session> [branch] [-f]` | Permanently remove a session (or a branch subtree) from Loom's records. Agent session files are left untouched. |
| `loom help` | Show usage. |

## How it's built

- **tmux** isolates each branch as `loom-<session>-<branch>`.
- Each agent persists its session as JSONL/rollout files — Loom never
  stores conversation content itself, it only splices/writes these
  files to create child sessions.
- A child branch's session file is **synthesized by the adapter** at
  fork time:
  - **`inherit_context=true`**: copy the parent's prefix up to the fork
    call, then append a synthesized "birth announcement" as the fork
    tool's output. CC rewrites each entry's `sessionId` to the child's
    id. Codex swaps `session_meta.id` and replaces the loom-prompt
    section of the developer role message with the child's rendered
    system prompt (so the model sees its own `BRANCH_ID`, not the
    parent's).
  - **`inherit_context=false`**: CC synthesizes a minimal two-entry
    file (synthetic fork `tool_use` + birth `tool_result`). Codex
    synthesizes nine entries that mirror a fresh first turn —
    `session_meta` and the developer role message are inherited from
    the parent (loom prompt re-rendered for the child); a synthetic
    `task_started`, inherited `turn_context`, inherited environment
    context, a `user_message` event (required for Codex's
    reconstruction to treat this as a real user turn so
    `reference_context_item` is captured and `build_initial_context`
    does not re-run), the fork `function_call`, its birth
    `function_call_output`, and `task_complete` close the turn.
- **SQLite** at `~/.loom/loom.db` holds only structure: which branches
  exist, who their parent is, what agent backs them, and the agent's
  own session id.
- An **MCP server** (under `src/mcp/`) exposes the `fork` / `send` /
  `checkout` tools to each agent instance over stdio. The same server
  binary is shared by both agents.
- Per-agent hooks do the heavy lifting once the parent's fork call
  has been flushed to disk:
  - CC: `PostToolUse` hook matches the fork tool_use.
  - Codex: `Stop` hook fires per turn; we filter by the existence of a
    pending-fork marker file.
- A **`system-prompt.md` template** is rendered per-branch with
  `{{BRANCH_ID}}` substituted, then delivered to each agent differently:
  - **CC**: passed on every launch (fresh and resume) via
    `--append-system-prompt`; CC does not bake it into the JSONL.
  - **Codex (fresh)**: passed via `-c developer_instructions=...` so
    Codex writes it into the rollout's developer role message at
    session start.
  - **Codex (resume)**: the flag is omitted — Codex does not rewrite
    the developer role message from `-c` on resume, so the system
    prompt for fork children is written directly into the child's
    synthesized rollout (see above) and read back when the child
    resumes.
- The **Adapter** pattern (`src/adapters/<agent>/*`) hides all
  agent-specific quirks behind a uniform interface. Upper layers
  (`src/cli/*`, `src/core/execute-fork`, `src/core/hook-runner`,
  `src/mcp/tools/*`) only call adapter methods, never reference a
  concrete agent.

## Repo layout

```
src/cli/            TypeScript CLI (new / list / attach / stop / rm)
src/mcp/            Shared MCP server: server.ts + tools/*
src/hooks/          Agent-specific hook entry points (thin wrappers)
src/adapters/       claude-code/ and codex/ implementations of AgentAdapter
src/core/           Agent-neutral business logic (execute-fork,
                    hook-runner, db, tmux, ...)
system-prompt.md    Template applied to every branch; {{BRANCH_ID}} is
                    substituted at launch time
__tests__/          Unit tests (Node test runner)

~/.loom/            Runtime state (created on first use): loom.db,
                    mcp-config.json, settings.json, pending-forks/,
                    debug.log (CC-specific files live here)
~/.codex/           Codex-side config loom writes into: hooks.json,
                    and the registered loom MCP via `codex mcp add`.
```

## DB schema

Version `user_version = 2`. Migrations run automatically on first
connect; pre-Adapter (v1) databases are upgraded in place without data
loss — `cc_session_id` is renamed to `agent_session_id` and an
`agent_type` column is added defaulting to `claude-code`.

## Status

Early. `fork` and `send` are fully implemented for both agents.
`checkout` is currently a stub on the MCP side — the user-facing
frontend integration is done externally (a Loom tree view in
[Agentboard](https://github.com/gbasin/agentboard), a tmux web GUI,
that consumes `~/.loom/loom.db` directly).

## License

MIT
