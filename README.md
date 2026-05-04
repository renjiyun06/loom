# Loom

> Parallel branching for Claude Code and Codex. Loom lets one agent
> conversation fork into real parallel agent sessions, then pass results
> back between branches.

## Status

Loom is early software. The implemented product surface is a local CLI,
an MCP server, tmux-managed agent processes, and SQLite runtime state.

Implemented today:

- `fork`: create a child branch backed by a new Claude Code or Codex
  agent session.
- `send`: deliver a message to another branch, relaunching that branch
  first when needed.
- CLI session management: `new`, `list`, `attach`, `relaunch`, `stop`,
  and `rm`.

Not implemented as a built-in product surface yet:

- A first-party frontend or checkout UI. A `checkout` tool stub exists in
  source, but the current MCP server exposes only `fork` and `send`.
- Cross-agent fork. A child branch currently inherits the parent's agent
  type.
- Conversation storage inside Loom. Agent transcript files remain owned
  by Claude Code or Codex; Loom stores only branch structure and runtime
  metadata.

## What Loom Is For

Most agent sessions are linear. That works for small tasks, but it gets
awkward when real work branches:

- one branch should investigate while another keeps implementing;
- a risky refactor needs a side exploration before committing to it;
- a parent agent wants a child to inspect a subsystem and report back;
- multiple independent hypotheses should run without losing the current
  conversation.

Loom models those cases as a branch tree. Each branch is a real agent
process in its own tmux session. A child branch can inherit the parent's
conversation prefix at the fork point, run independently, and send a
summary or result back to another branch.

Loom is not a replacement for git, a task queue, or an agent-hosting
service. It does not merge code, reconcile conflicting edits, provide
remote orchestration, or hide the underlying agent CLIs. It is a local
coordination layer for people who already work in terminal-based agent
workflows.

## Requirements

- Linux/macOS shell environment with `tmux`
- Node.js 22 or newer
- `sqlite3`
- At least one supported agent CLI:
  - Claude Code: `claude`
  - Codex CLI v0.120 or newer: `codex`

Loom writes runtime files under `~/.loom/`. Codex integration also writes
Codex-side configuration under `~/.codex/`.

## Quick Start

Install and build:

```bash
git clone https://github.com/renjiyun06/loom.git
cd loom
npm install
npm run build
npm link
```

Validate the checkout:

```bash
npm test
loom help
```

Start a first session with Claude Code:

```bash
loom new
```

Or start one with Codex:

```bash
loom new --agent codex
```

`loom new` creates a Loom session, creates the `main` branch, writes the
required agent configuration, starts the agent inside tmux, and attaches
your terminal to it. The command prints a short Loom session id such as
`a1b2c3d4`; keep that id for follow-up CLI commands.

Detach from tmux with `Ctrl-B d`. From another terminal:

```bash
loom list
loom attach <session-id>
```

If the tmux process died but the branch is still registered, `loom
attach` relaunches the agent before attaching.

## Agent Setup Details

### Claude Code

Claude Code is the default agent:

```bash
loom new --agent claude-code
```

On launch, Loom writes:

- `~/.loom/mcp-config.json`: registers the compiled Loom MCP server.
- `~/.loom/settings.json`: installs a `PostToolUse` hook for fork
  handling.

Loom launches `claude` with `--mcp-config`, `--settings`,
`--append-system-prompt`, and `--dangerously-skip-permissions`. The tmux
process carries `LOOM_SESSION` and `LOOM_BRANCH`, which the MCP server
requires.

Claude Code session files remain in Claude Code's normal project JSONL
location under `~/.claude/projects/...`.

### Codex

Codex sessions are started explicitly:

```bash
loom new --agent codex
```

On launch, Loom:

- registers the Loom MCP server with `codex mcp add loom -- node
  <repo>/dist/mcp/server.js`;
- writes `~/.codex/hooks.json` with a `Stop` hook pointing at Loom's
  compiled Codex hook;
- runs `codex features enable codex_hooks`;
- starts Codex with branch-specific MCP environment values
  (`LOOM_SESSION` and `LOOM_BRANCH`).

Codex rollout files remain in Codex's normal location:

```text
~/.codex/sessions/YYYY/MM/DD/...
```

For fresh Codex sessions, Loom injects the branch system prompt through
`developer_instructions`. For resumed Codex branches, Loom relies on the
developer message already stored in the synthesized rollout file.

## End-to-End Example

Start a session:

```bash
loom new --agent codex
```

Inside the agent, ask it to fork a side task. The exact UI depends on
the agent, but the MCP call is:

```text
fork(
  instruction: "Inspect the authentication module and report the request flow.",
  inherit_context: true
)
```

The tool result looks like:

```text
Branch 7b2e1c4d created.
```

The parent branch stays active while the child runs in a separate tmux
session. In another terminal:

```bash
loom list
loom attach <session-id> 7b2e1c4d
```

When a branch needs to report back, use the MCP `send` tool from inside
that branch:

```text
send(
  target: "main",
  content: "Auth uses JWT verification in middleware before route handlers."
)
```

The target branch receives a normal user turn prefixed with the sender:

```text
[loom: from branch 7b2e1c4d] Auth uses JWT verification in middleware before route handlers.
```

Common follow-up commands:

```bash
loom list --json
loom relaunch <session-id> 7b2e1c4d
loom stop <session-id> 7b2e1c4d --only
loom stop <session-id>
loom attach <session-id> main
```

`stop` only kills tmux processes. The registered session and branch rows
stay in `~/.loom/loom.db`, so `attach`, `relaunch`, or `send` can start
the branch again.

## CLI Reference

| Command | Behavior |
| --- | --- |
| `loom new [--agent <type>]` | Start a new Loom session on branch `main`, then attach to its tmux session. `--agent` accepts `claude-code`, `cc`, or `codex`; default is `claude-code`. |
| `loom list` | Print all recorded sessions as trees. Each branch shows agent type, tmux liveness, inherit/isolated status, and a truncated instruction. |
| `loom list --json` | Emit `{ "sessions": [...] }` with flat branch arrays per session. Branch records include `id`, `parent_id`, `agent_type`, `agent_session_id`, `inherit_context`, `instruction`, `alive`, `tmux_name`, and `created_at`. Instructions are not truncated. |
| `loom attach <session> [branch]` | Attach to a branch tmux session. Default branch is `main`. If the branch is registered but tmux is dead, Loom rebuilds the launch command, relaunches the agent, waits briefly, then attaches. |
| `loom relaunch <session> [branch]` | Ensure a branch tmux session is alive without attaching. Default branch is `main`. Prints one machine-parseable line: `already-alive: <tmux-name>` or `launched: <tmux-name>`. |
| `loom stop <session>` | Kill every live tmux session whose name belongs to the Loom session. Database rows and agent session files are preserved. Exits with an error if no live tmux sessions match. |
| `loom stop <session> <branch>` | Kill the branch and all registered descendants, descendants first. Database rows and agent session files are preserved. |
| `loom stop <session> <branch> --only` | Kill only that branch's tmux session. Descendant branches are left alone. |
| `loom rm <session> [branch] [-f]` | Permanently remove a whole session or branch subtree from Loom's database and delete pending-fork files. Matching tmux sessions are killed. Agent session files are left untouched. `-f` skips confirmation. |
| `loom help` | Show usage and runtime paths. |

## Troubleshooting

### `loom: no live tmux sessions for <session>`

`loom stop <session>` only targets live tmux sessions. Check recorded
branches first:

```bash
loom list
```

If the branch is still registered, wake it directly:

```bash
loom relaunch <session> main
loom attach <session> main
```

### A branch is recorded but the agent is not running

Use `relaunch` or `attach`; both rebuild the branch launch script from
the database:

```bash
loom relaunch <session> <branch>
```

If relaunch fails, verify the repo was built and the required agent
binary is on `PATH`:

```bash
npm run build
which claude
which codex
```

Loom launch scripts are written under `~/.loom/` as
`session-<session>-<branch>-launch.sh`.

### Codex fork calls create a branch row but no child starts

Codex fork execution depends on hooks. Check:

```bash
codex features enable codex_hooks
cat ~/.codex/hooks.json
cat ~/.loom/debug.log
```

Running `loom new --agent codex` or relaunching a Codex branch rewrites
the Codex MCP registration and hook file.

### MCP server reports missing `LOOM_SESSION` or `LOOM_BRANCH`

The MCP server expects Loom branch context in environment variables.
Start agents through `loom new`, `loom attach`, `loom relaunch`, or
`send` relaunches. Starting `node dist/mcp/server.js` by hand will not
have enough context.

For Claude Code, the variables are inherited from the tmux process. For
Codex, Loom injects them through Codex MCP server environment config on
each launch.

### SQLite or runtime files are confusing

Runtime state lives here:

```text
~/.loom/loom.db
~/.loom/mcp-config.json
~/.loom/settings.json
~/.loom/pending-forks/
~/.loom/send-locks/
~/.loom/debug.log
~/.loom/session-<session>-<branch>-launch.sh
```

The database stores structure only: sessions, branches, parent links,
agent type, agent session id, instructions, inherit flags, and
timestamps. It does not store conversation content.

### `loom attach` says the branch or session is not registered

The tmux session name alone is not enough. Loom must also have matching
rows in `~/.loom/loom.db`. Use `loom list` to find valid session and
branch ids. If the rows were removed with `loom rm`, start a new Loom
session.

## How It Works

```
Branch main (agent=codex)
├─ user: "Refactor the auth module"
├─ assistant: fork("Explore current auth structure") ──┐
│                                                       │
│                      Branch 7b2e1c4d (parallel)      │
│                      ├─ reads code                   │
│                      ├─ builds summary               │
│                      └─ send(main, "Auth uses JWT...")│
│                                                       │
├─ assistant: "Meanwhile I will draft goals" ──────────┘
├─ [from 7b2e1c4d] Auth uses JWT...
└─ assistant: "Based on that, here is the plan..."
```

`fork` allocates a child branch id, inserts a branch row, and writes a
pending-fork marker. The actual child session file is synthesized from
the parent's flushed transcript in an agent hook:

- Claude Code: `PostToolUse` hook.
- Codex: `Stop` hook, filtered by pending-fork marker.

`send` writes a `[loom: from branch <id>] ...` line into the target
branch's tmux session. If tmux is not alive but the branch is
registered, Loom starts the target first.

Each child branch's session file is built by the active agent adapter:

- `inherit_context=true`: copy the parent's conversation prefix through
  the fork call, then append a synthesized birth result.
- `inherit_context=false`: synthesize a minimal isolated session that
  still contains the fork instruction and enough agent-specific metadata
  to resume correctly.

For Claude Code child files, Loom rewrites entries to the child
`sessionId`. For Codex child rollouts, Loom updates `session_meta.id`
and rewrites the Loom section of the developer message so the child sees
its own branch id.

## Architecture

- `tmux` isolates each branch as `loom-<session>-<branch>`.
- `~/.loom/loom.db` stores the branch tree and agent metadata.
- The shared MCP server in `src/mcp/` exposes the implemented tools:
  `fork` and `send`.
- Agent hooks in `src/hooks/` execute pending fork work after the
  parent agent has flushed the fork call to disk.
- The adapter layer in `src/adapters/` contains Claude Code and Codex
  session-file, hook-payload, and launch-command differences.
- `system-prompt.md` is rendered per branch with `{{BRANCH_ID}}`.

## Repo Layout

```text
src/cli/            TypeScript CLI commands
src/mcp/            Shared MCP server and tools
src/hooks/          Agent-specific hook entry points
src/adapters/       Claude Code and Codex adapters
src/core/           Agent-neutral runtime logic
system-prompt.md    Per-branch system prompt template
__tests__/          Node test runner tests
```

## Database Schema

The current schema uses `PRAGMA user_version = 2`. Migrations run
automatically on open. Pre-adapter databases are upgraded in place:
`cc_session_id` is renamed to `agent_session_id`, and `agent_type` is
added with a default of `claude-code`.

## Development

```bash
npm install
npm run build
npm test
npm run dev
```

The package binary points at `dist/cli/index.js`, so rebuild after
changing TypeScript before testing the installed `loom` command.

## License

MIT
