---
tracker:
  kind: linear
  project_slug: "6b0687bf0474"
  api_key: $LINEAR_API_KEY
  active_states:
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
polling:
  interval_ms: 5000
server:
  host: 0.0.0.0
workspace:
  root: /home/lamarck/.symphony/workspaces/loom
hooks:
  after_create: |
    set -eux
    if command -v gh >/dev/null 2>&1; then
      gh repo clone renjiyun06/loom .
    else
      git clone https://github.com/renjiyun06/loom.git .
    fi
    git status --short --branch
    if [ -f package-lock.json ] && command -v npm >/dev/null 2>&1; then
      npm ci
    elif [ -f package.json ] && command -v npm >/dev/null 2>&1; then
      npm install
    fi
    if [ -f package.json ] && command -v npm >/dev/null 2>&1 && npm run | grep -qE '^  build$|^    build$|^build$'; then
      npm run build
    fi
  before_run: |
    set -eux
    git status --short --branch
  after_run: |
    git status --short --branch || true
agent:
  max_concurrent_agents: 1
  max_turns: 3
codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=high app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
---
You are working on Linear ticket `{{ issue.identifier }}` for `renjiyun06/loom`.

{% if attempt %}
Continuation:
- Resume from the existing workspace and the `## Codex Workpad` comment.
- Do not repeat completed work unless the issue, PR, or comments changed.
{% endif %}

Issue:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- Status: {{ issue.state }}
- Labels: {{ issue.labels }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Rules:
1. Work only inside this checkout of `renjiyun06/loom`.
2. Do not ask for human input during the run. If blocked, record the blocker in Linear, move the issue to Blocked, and stop.
3. Use `linear_graphql` when available for issue reads, comments, state changes, and PR attachments.
4. Maintain exactly one Linear comment headed `## Codex Workpad` for plan, validation, notes, blockers, and handoff.
5. Prefer small, reviewable changes. Do not do broad rewrites unless the issue explicitly asks for one.
6. Do not expose secrets or credentials in files, commits, comments, logs, or PR text.
7. Before editing, inspect the repo and identify the correct build/test/lint commands from existing files.
8. Do not use the `land` skill or merge PRs unless the issue explicitly asks for merge/landing.

Branch and PR:
1. Never commit directly on `main`.
2. Before editing, fetch `origin` and create or switch to `symphony/<lowercase issue identifier>` from `origin/main`.
3. If an open PR already exists for this issue branch, continue that branch/PR.
4. If the branch is tied to a closed or merged PR, create a fresh branch from `origin/main` before continuing.
5. Record the branch and HEAD short SHA in the workpad.

State handling:
- Backlog: stop without changing files.
- Todo: move to In Progress, update the workpad, then execute.
- In Progress: continue active work from the workspace and workpad.
- Rework: read Linear comments and PR review/comments, reuse the existing PR when appropriate, implement only the requested changes, then return to Human Review.
- Blocked: stop without coding or rechecking.
- Human Review: stop without coding or rechecking.
- Done/Closed/Cancelled/Canceled/Duplicate: stop.

Completion rule:
- When validation passes and the PR handoff is complete, move the issue to Human Review.
- Never leave completed work in In Progress.
- When progress is impossible without human input, permission, external dependency, or environment repair, update the workpad with the blocker and move the issue to Blocked.
- If Human Review does not exist, record a workflow-configuration blocker in the workpad and stop.

Workpad format:
```md
## Codex Workpad

```text
<hostname>:<abs-workdir>@<short-sha>
```

### Plan
- [ ] ...

### Acceptance Criteria
- [ ] ...

### Validation
- [ ] command: `<command>` — result: `<pending|pass|fail>`

### Notes
- <timestamp> <short note>

### Confusions
- <only if something is unclear>
```

Execution flow:
1. Read the current issue, comments, and PR state.
2. Apply the state handling rules above.
3. Create or update the workpad.
4. Create or switch to the issue branch.
5. Inspect the relevant code/docs and current commands.
6. Capture a baseline validation signal when useful.
7. Implement the smallest useful change.
8. Run targeted validation; use the strongest practical validation if full validation is expensive or unavailable.
9. Commit with a concise message.
10. Push and open or update the PR.
11. Attach or record the PR in Linear.
12. Update the workpad with final checklist, validation evidence, commit/PR info, and blockers/confusions.
13. Move the issue to Human Review after successful handoff.
