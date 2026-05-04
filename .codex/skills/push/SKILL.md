---
name: push
description:
  Push the current Loom feature branch to origin and create or update the
  corresponding pull request; use when asked to push, publish updates, or create
  a pull request.
---

# Push

## Prerequisites

- `gh` CLI is installed and available in `PATH`.
- `gh auth status` succeeds for GitHub operations in this repo.
- You are not on `main`; every Symphony issue must work on a dedicated feature
  branch.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR if none exists for the branch, otherwise update the existing PR.
- Keep branch history clean when remote has moved.
- Link the PR back to the Linear issue when `linear_graphql` is available.

## Related Skills

- `pull`: use this when push is rejected or sync is not clean.
- `linear`: use this to attach the PR to the Linear issue.

## Branch rule

Before pushing, verify:

```sh
branch=$(git branch --show-current)
test -n "$branch"
test "$branch" != "main"
```

If currently on `main`, create a dedicated branch from `origin/main` before
committing or pushing. Recommended branch name for Symphony runs:

```text
symphony/<lowercase-linear-issue-identifier>
```

Example: `symphony/loom-123`.

## Validation gate for Loom

Prefer the strongest relevant validation for the change. For ordinary code
changes in this repository, run:

```sh
npm run build
npm test
```

If a command is unavailable or irrelevant, document the reason in the Linear
workpad and use the strongest targeted proof available.

## Steps

1. Identify current branch and confirm remote state.
2. Confirm branch is not `main`.
3. Run local validation appropriate to the change. Default Loom gate:
   - `npm run build`
   - `npm test`
4. Push branch to `origin` with upstream tracking if needed, using the existing
   remote URL:
   - `git push -u origin HEAD`
5. If push is rejected because the branch is stale, run the `pull` skill to merge
   `origin/main`, resolve conflicts, rerun validation, and push again.
6. If push fails because of auth/permissions, record the exact blocker in the
   Linear workpad instead of rewriting remotes or changing credentials.
7. Ensure a PR exists for the branch:
   - If no PR exists, create one.
   - If a PR exists and is open, update title/body if the scope changed.
   - If the branch is tied to a closed/merged PR, create a new branch from
     `origin/main` and a fresh PR.
8. Write a concrete PR title and body:
   - Summarize what changed.
   - Include validation commands and results.
   - Include risk/rollback notes when relevant.
   - Do not include secrets or private credentials.
9. If `linear_graphql` is available, attach the GitHub PR to the Linear issue
   using the `linear` skill. Otherwise record the PR URL in the workpad.
10. Reply/update workpad with the PR URL from `gh pr view`.

## Commands

```sh
branch=$(git branch --show-current)
if [ -z "$branch" ] || [ "$branch" = "main" ]; then
  echo "Refusing to push from main; create a feature branch first" >&2
  exit 1
fi

npm run build
npm test

git push -u origin HEAD

pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)
if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
  echo "Current branch is tied to a closed PR; create a new branch + PR." >&2
  exit 1
fi

pr_title="<clear PR title written for this change>"
pr_body_file=$(mktemp)
cat > "$pr_body_file" <<'PR_BODY'
## Summary
- <what changed>

## Validation
- [ ] npm run build
- [ ] npm test

## Notes
- <risks, limitations, or none>
PR_BODY

if [ -z "$pr_state" ]; then
  gh pr create --title "$pr_title" --body-file "$pr_body_file"
else
  gh pr edit --title "$pr_title" --body-file "$pr_body_file"
fi
rm -f "$pr_body_file"

gh pr view --json url -q .url
```

## Notes

- Do not use `--force`; only use `--force-with-lease` when history was
  intentionally rewritten and the lease is safe.
- Distinguish sync problems from auth/permission problems:
  - Use the `pull` skill for stale-branch/non-fast-forward issues.
  - Surface auth/permission failures directly in the Linear workpad.
- Do not push generated build artifacts unless the repository already tracks
  them intentionally.
