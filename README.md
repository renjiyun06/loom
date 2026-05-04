# Loom

> Parallel branching for **Claude Code and Codex**. Loom turns a
> single agent conversation into a forkable tree of tmux-backed agent
> sessions with message passing between branches.

## Status

Loom is early project infrastructure, not a polished frontend product.
The current implementation focuses on the terminal/runtime layer:

- Implemented: `fork` and `send` MCP tools for Claude Code and Codex.
- Implemented: CLI lifecycle commands for creating, listing, attaching,
  relaunching, stopping, and removing Loom sessions.
- Not bundled: a first-party graphical frontend.
- Not currently exposed: the old `checkout` MCP idea. Frontends can
  still consume `~/.loom/loom.db` and `loom list --json`, but the MCP
  server currently exposes only `fork` and `send`.
- Not supported yet: cross-agent forks. A child branch inherits the
  parent's agent type.

## What Loom Is For

Most agent CLIs are linear: one working directory, one terminal, one
conversation timeline. That is awkward when the work naturally branches:
you may want one agent to investigate an unfamiliar subsystem, another
to try a low-risk patch, and the parent to keep planning without
blocking on either result.

Loom gives that workflow three concrete properties:

- **Parallelism**: each branch is a real Claude Code or Codex process in
  its own named tmux session.
- **Shared prefix**: a forked child can inherit the parent's conversation
  history up to the fork call, then continue independently.
- **Message passing**: branches can send short handoff messages to one
  another without merging terminal state or rewriting history.

Good fits:

- exploratory codebase investigation while the parent keeps working;
- bounded implementation or verification subtasks;
- agent dashboards or editor extensions that need a stable session tree;
- long-running terminal workflows where branch state must survive
  detach/reattach.

Poor fits:

- replacing git branches, worktrees, or code review;
- running untrusted agents without sandboxing;
- browser-style visual branch switching out of the box;
- mixing Claude Code parent sessions with Codex child sessions.

## Quick Start

### 1. Install Prerequisites

Install the runtime tools:

- `node` 22 or newer
- `npm`
- `tmux`
- `sqlite3`

Install at least one supported agent CLI:

- Claude Code: the `claude` command
- Codex CLI v0.120 or newer: the `codex` command

### 2. Build Loom

```bash
git clone https://github.com/renjiyun06/loom.git
cd loom
npm ci
npm run build
npm test
npm link
```

`npm link` makes the compiled `loom` command available on your `PATH`.
If you skip it, run the CLI with `node dist/cli/index.js`.

### 3. Start a Session

From the project directory you want the agent to work in:

```bash
# Claude Code is the default.
loom new

# Equivalent explicit form.
loom new --agent claude-code

# Or start with Codex.
loom new --agent codex
```

`loom new` creates a Loom session, registers the `main` branch in
`~/.loom/loom.db`, starts the agent inside `tmux`, and attaches your
terminal. Detach with `Ctrl-B d`.

### 4. Run a Minimal Branch Workflow

Inside the attached agent, ask it to use Loom's `fork` tool:

```text
Use the loom fork tool to investigate the test structure and report
back to main. Inherit context.
```

The tool call creates a child branch and starts another tmux session in
the background. In another terminal:

```bash
loom list
loom list --json
```

Attach to the child branch if you want to watch or interact with it:

```bash
loom attach <session-id> <child-branch-id>
```

From either branch, the agent can use the `send` tool to report back:

```text
Use the loom send tool with target "main" and content "The test suite is
under __tests__ and npm test runs build plus node --test."
```

If a registered branch's tmux session is dead, wake it without attaching:

```bash
loom relaunch <session-id> <branch-id>
```

Stop live tmux sessions while keeping the Loom records:

```bash
loom stop <session-id>                  # stop every live branch
loom stop <session-id> <branch-id>      # stop branch and descendants
loom stop <session-id> <branch-id> --only
```

Because `stop` preserves database rows, `loom attach` and
`loom relaunch` can start registered branches again.

## Agent Setup Differences

Loom configures the selected agent when you run `loom new`. The two
agents need different hook and MCP wiring.

### Claude Code

Claude Code sessions store JSONL files under:

```text
~/.claude/projects/<encoded-cwd>/*.jsonl
```

Loom writes Claude-specific config under `~/.loom/`:

- `~/.loom/mcp-config.json`: registers the compiled Loom MCP server.
- `~/.loom/settings.json`: installs a `PostToolUse` hook matching fork
  tool calls.

Claude Code receives Loom branch context from the tmux environment:

```text
LOOM_SESSION=<session-id>
LOOM_BRANCH=<branch-id>
```

Loom launches Claude Code with `--append-system-prompt`, `--mcp-config`,
`--settings`, and `--dangerously-skip-permissions`.

### Codex

Codex rollouts are stored under:

```text
~/.codex/sessions/YYYY/MM/DD/*.jsonl
```

Loom performs three Codex setup steps:

- registers the MCP server with `codex mcp add loom`;
- writes `~/.codex/hooks.json` with a `Stop` hook pointing at Loom's
  compiled hook;
- runs `codex features enable codex_hooks`.

Codex receives Loom branch context through the per-launch MCP config:

```text
mcp_servers.loom.env={LOOM_SESSION="<session-id>",LOOM_BRANCH="<branch-id>"}
```

For fresh Codex sessions, Loom also passes the branch system prompt via
`developer_instructions`. On resume, Loom relies on the rollout's stored
developer message instead.

## CLI Reference

| Command | What it does |
|---------|--------------|
| `loom new [--agent <type>]` | Start a new Loom session on a fresh `main` branch and attach to it. Agent type defaults to `claude-code`; valid values are `claude-code`, `cc`, and `codex`. |
| `loom list` | Print all sessions as human-readable branch trees. Each branch shows agent type, tmux liveness, inherit/isolated state, and a truncated instruction. |
| `loom list --json` | Emit `{ "sessions": [...] }` for tooling. Branches are a flat array per session with `parent_id` links. `instruction` is not truncated. |
| `loom attach <session> [branch]` | Attach to a branch tmux session. If the tmux session is dead but the branch is still registered, relaunch the agent first. Default branch: `main`. |
| `loom relaunch <session> [branch]` | Ensure a branch tmux session is alive without attaching. Prints `already-alive: <tmux-name>` or `launched: <tmux-name>`. Default branch: `main`. |
| `loom stop <session>` | Kill every live tmux session whose name belongs to the Loom session. Database records are preserved. |
| `loom stop <session> <branch>` | Kill that branch and all descendants, leaves first. Database records are preserved. |
| `loom stop <session> <branch> --only` | Kill only that one branch's tmux session. Database records are preserved. |
| `loom rm <session> [branch] [-f]` | Permanently remove a whole session or a branch subtree from Loom's database. Kills affected tmux sessions and removes pending-fork files. Agent session files are left untouched. `-f` skips confirmation. |
| `loom help`, `loom --help`, `loom -h` | Show CLI usage. |

## MCP Tools

The MCP server is shared by both agents and currently exposes:

| Tool | Arguments | Result |
|------|-----------|--------|
| `fork` | `instruction` string, optional `inherit_context` boolean defaulting to `true` | Allocates a child branch, records it in SQLite, writes a pending-fork marker, and lets the agent hook synthesize and launch the child session. |
| `send` | `target` branch id, `content` string | Sends `[loom: from branch <id>] ...` into the target branch's tmux session. If the target branch is registered but not alive, Loom relaunches it first. |

## Troubleshooting

### `loom: MCP server not built`

Run:

```bash
npm ci
npm run build
```

Loom launches `dist/mcp/server.js`, so the TypeScript build must exist
before `loom new`, `loom attach`, or `loom relaunch` can start agents.

### Missing `tmux`, `sqlite3`, `claude`, or `codex`

`loom new` checks required binaries before launch. Install the missing
command and make sure it is visible on `PATH` from the shell where you
run `loom`.

### `tmux` session does not exist

Use `loom list` to confirm the Loom session and branch ids. If the
branch is still registered but marked dead, run:

```bash
loom relaunch <session-id> <branch-id>
loom attach <session-id> <branch-id>
```

If the branch was removed with `loom rm`, it cannot be relaunched from
Loom's database.

### Agent starts but `fork` is not available

Check that the selected agent was launched through `loom new`, not
directly through `claude` or `codex`. The MCP server also requires:

```text
LOOM_SESSION
LOOM_BRANCH
```

These are set by Loom's tmux launch path. Running the MCP server by hand
without them will fail.

### Codex fork calls do nothing

Codex needs hook support enabled. Re-run a Codex Loom session setup:

```bash
loom new --agent codex
```

Then verify:

```bash
codex features list
cat ~/.codex/hooks.json
codex mcp list
```

The hook file should contain a `Stop` hook for Loom, and the MCP list
should include `loom`.

### Claude Code hook does not fire

Claude Code uses Loom's per-launch config files:

```text
~/.loom/mcp-config.json
~/.loom/settings.json
```

Start the session through `loom new --agent claude-code` so Claude Code
receives those files and the `PostToolUse` hook.

### Where runtime files live

```text
~/.loom/loom.db                         # session and branch structure
~/.loom/pending-forks/                  # fork jobs waiting for hooks
~/.loom/send-locks/                     # send serialization locks
~/.loom/debug.log                       # hook/fork debug log
~/.loom/session-<sid>-<branch>-*.sh     # per-branch launch scripts
~/.loom/session-<sid>-<branch>-prompt.txt
~/.claude/projects/.../*.jsonl          # Claude Code conversation files
~/.codex/sessions/YYYY/MM/DD/*.jsonl    # Codex rollout files
~/.codex/hooks.json                     # Codex hook config
```

Loom's database stores structure only. Conversation content remains in
the agent's own session files.

## How It Works

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

`fork` allocates a child branch id, stores it in SQLite, and writes a
pending-fork file keyed by the parent agent session id. The agent hook
then waits for the parent's fork call to be flushed to disk, synthesizes
the child session file, and starts the child agent in a tmux session.

`send` writes a prefixed message into another branch's tmux session. If
the target is registered but dead, Loom relaunches the agent first and
then sends the message.

Each branch is named:

```text
loom-<session-id>-<branch-id>
```

## Implementation Notes

- **tmux** isolates each branch as its own terminal session.
- **SQLite** at `~/.loom/loom.db` stores sessions, branch parentage,
  agent type, agent session id, instruction, and timestamps.
- **MCP** under `src/mcp/` exposes the `fork` and `send` tools over
  stdio. The same server binary is used by both agents.
- **Hooks** finish fork execution after the parent agent has written the
  fork tool call to disk:
  - Claude Code: `PostToolUse` hook matches fork tool calls.
  - Codex: `Stop` hook fires each turn; Loom filters by pending-fork
    marker.
- **System prompt rendering** uses `system-prompt.md` with
  `{{BRANCH_ID}}` substituted per branch.
- **Adapters** under `src/adapters/<agent>/` isolate Claude Code and
  Codex session-file, launch, hook, and resume behavior from the shared
  CLI/core layers.

Child session synthesis differs by `inherit_context`:

- `inherit_context=true`: copy the parent's history prefix through the
  fork call, then append a synthesized birth-announcement tool result.
  Claude Code rewrites each entry's `sessionId`; Codex rewrites
  `session_meta.id` and the Loom prompt section in the developer
  message.
- `inherit_context=false`: synthesize a minimal child session that
  contains enough agent-native structure for the child to treat the fork
  as its starting point without inheriting the full parent conversation.

## Repo Layout

```text
src/cli/            TypeScript CLI (new/list/attach/relaunch/stop/rm)
src/mcp/            Shared MCP server and tools
src/hooks/          Agent-specific hook entry points
src/adapters/       Claude Code and Codex adapter implementations
src/core/           Agent-neutral database, tmux, fork, launch logic
system-prompt.md    Per-branch system prompt template
__tests__/          Node test runner tests
dist/               Compiled JavaScript output
```

## Database Schema

Current schema version: `user_version = 2`.

Migrations run automatically when Loom opens the database. Pre-adapter
v1 databases are upgraded in place: `cc_session_id` is renamed to
`agent_session_id`, and an `agent_type` column is added with
`claude-code` as the default.

## Development

```bash
npm ci
npm run build
npm test
npm run clean
```

The test script runs `npm run build` first, then Node's built-in test
runner over `__tests__/**/*.test.mjs`.

## License

MIT
