---
name: land
description:
  Land a Loom PR by monitoring conflicts, resolving them, waiting for checks,
  and squash-merging when green; use only when the Linear issue is explicitly in
  a merge/land state and the PR has human approval.
---

# Land

## Goals

- Ensure the PR is conflict-free with `origin/main`.
- Keep validation and CI green.
- Address outstanding human or bot review feedback before merge.
- Squash-merge the PR when approved and green.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch with a clean working tree.
- The PR has explicit human approval or the Linear issue is in a state that means
  approved-for-merge.
- You are not on `main`.

## Steps

1. Locate the PR for the current branch with `gh pr view`.
2. Confirm local validation is green for Loom:
   - `npm run build`
   - `npm test`
3. If the working tree has uncommitted changes, commit with the `commit` skill
   and push with the `push` skill before proceeding.
4. Check mergeability and conflicts against main.
5. If conflicts exist, use the `pull` skill to merge `origin/main`, resolve
   conflicts, rerun validation, and use the `push` skill to publish.
6. Gather PR review comments and check runs. Treat actionable unresolved review
   feedback as blocking until fixed or explicitly answered.
7. Watch checks until complete. If checks fail, inspect logs, fix, commit, push,
   and re-run validation/checks.
8. When approved, conflict-free, and green, squash-merge using the PR title/body.
9. Update the Linear workpad with merge evidence and move the issue to Done when
   the workflow permits.

## Commands

```sh
branch=$(git branch --show-current)
if [ -z "$branch" ] || [ "$branch" = "main" ]; then
  echo "Refusing to land from main" >&2
  exit 1
fi

npm run build
npm test

pr_number=$(gh pr view --json number -q .number)
pr_title=$(gh pr view --json title -q .title)
pr_body=$(gh pr view --json body -q .body)
mergeable=$(gh pr view --json mergeable -q .mergeable)

if [ "$mergeable" = "CONFLICTING" ]; then
  echo "PR has conflicts; run the pull skill, resolve, validate, and push" >&2
  exit 1
fi

gh pr checks --watch
gh pr merge --squash --subject "$pr_title" --body "$pr_body"
```

## Notes

- Do not enable auto-merge unless explicitly requested.
- Do not merge while actionable review comments are outstanding.
- If CI is absent, rely on local validation and state that in the workpad.
- Prefer squash merge for clean issue-level history unless the repo policy says
  otherwise.
