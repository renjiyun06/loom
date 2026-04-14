# Loom

> Parallel branching system for Claude Code — turn a single-threaded conversation into a forkable, parallel, and message-passing tree.

## What & Why

A normal Claude Code session is linear: you and the agent walk down one
thread of context together. If you want to explore a side question, you
either start a fresh session (losing context) or rewind (losing what
came after). Neither composes well with the way real work branches.

Loom answers this with three primitives:

- **`fork`** — spawn a new branch with its own Claude Code instance
  running in parallel. The child inherits the conversation up to the
  fork point; you keep working on the parent.
- **`send`** — deliver a message to another branch. Use it to ask a
  question, hand off a sub-task, or report a result back.
- **`checkout`** — ask the user's frontend to switch focus to another
  branch. Pure view-layer; no data effect.

Branches are full Claude Code instances, not "thoughts" or "rewinds".
They actually run, in their own tmux sessions, in parallel, and share
exactly the prefix of history that existed at the moment of fork.

## How it works

```
Branch main
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

**`fork`** allocates a new branch id, creates a child JSONL by copying
the parent's conversation up to (and including) the fork call, then
launches a fresh Claude Code instance on that JSONL inside its own tmux
session. The child sees a "birth announcement" telling it who it is.

**`send`** writes a `[loom: from branch <id>] ...` line into the
target branch's tmux. If the target's agent is dormant, it gets started
on demand. The receiver sees the message as a normal user turn.

**`checkout`** is a thin signal to the user's frontend (e.g. a web
GUI watching loom's tmux sessions) to switch focus to a given branch.
It does not move the caller and does not modify any branch's history.

## Quick start

**Prerequisites**
- [Claude Code](https://docs.claude.com/claude-code) (the `claude` CLI)
- `tmux`, `node` (≥ 18), `sqlite3`, `openssl`, `python3`

**Install**

```bash
git clone https://github.com/renjiyun06/loom.git
cd loom
(cd mcp && npm install && npm run build)
ln -s "$PWD/bin/loom" ~/.local/bin/loom   # or put bin/ on your PATH
```

**Use**

```bash
# Start a new Loom session — drops you into Claude Code on the `main` branch
loom new

# Inside Claude, call the `fork` tool to spawn a parallel branch:
#   fork(instruction: "Investigate X and report back",
#        inherit_context: true)
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
| `loom new` | Start a new Loom session on a fresh `main` branch. |
| `loom list` | Print all sessions and their branch trees, marking alive/dead and inherit/isolated. |
| `loom attach <session> [branch]` | Attach to a branch's tmux. Relaunches the Claude Code instance if the tmux is dead but the branch is registered. Default branch: `main`. |
| `loom stop <session> [branch]` | Kill tmux for a session (or one of its branches). DB registrations are preserved. |
| `loom help` | Show usage. |

## How it's built

- **tmux** isolates each branch as `loom-<session>-<branch>`.
- **Claude Code's JSONL files** (`~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`)
  are the source of truth for conversation history. Loom never stores
  conversation content itself.
- A child branch's JSONL is a **copy of the parent's JSONL prefix** up
  to the fork call, with `sessionId` rewritten and a synthesized
  "birth announcement" appended.
- **SQLite** at `~/.loom/loom.db` holds only the structure: which
  branches exist, who their parent is, which Claude Code session UUID
  backs them.
- An **MCP server** (under `mcp/`) exposes the `fork` / `send` /
  `checkout` tools to each Claude Code instance over stdio.
- A **PostToolUse hook** runs after each `fork` call to do the heavy
  lifting (JSONL slicing, child launch) only once the parent's fork
  call has been flushed to disk.
- A **`system-prompt.md` template** is appended to every branch's
  Claude Code instance, teaching the agent how to recognize its own
  identity and how to use the three cross-branch tools.

## Repo layout

```
bin/loom            Bash CLI: new / list / attach / stop
mcp/                MCP server (TypeScript) — fork/send/checkout tools,
                    plus the PostToolUse hook for fork completion
system-prompt.md    Template appended to every branch's system prompt;
                    {{BRANCH_ID}} is substituted at launch time
~/.loom/            Runtime state (created on first use): loom.db,
                    mcp-config.json, settings.json, debug.log
```

## Status

MVP. `fork` and `send` are fully implemented. `checkout` is currently
a stub on the MCP side — the user-facing frontend integration is done
externally (we wired a Loom tree view into [Agentboard](https://github.com/gbasin/agentboard),
a tmux web GUI, that consumes `~/.loom/loom.db` directly).

## License

MIT
