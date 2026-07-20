---
name: submit-pr
description: Submit Git work as a pull request by creating or reusing a `submit-pr/` branch, staging all repository changes, generating a Conventional Commit, pushing to `origin`, and opening a GitHub pull request. Use only when the user explicitly invokes `$submit-pr`; never trigger implicitly from generic requests to commit, push, or create a pull request. Treat text following the invocation as optional context for the commit and pull request.
---

# Submit PR

Submit the current repository's work as one pull request. Treat an explicit `$submit-pr` invocation as authorization for this exact workflow in the resolved project, not for unrelated repositories or broader Git history changes.

## Inputs and Invariants

- Require a filesystem-backed Git project with `git`, `gh`, and an `origin` remote hosted on GitHub. If the project root is ambiguous, ask the user to identify it before changing state.
- Treat invocation text after `$submit-pr` as optional context. Reconstruct the actual change from Git; never let the context override the staged diff.
- Include all tracked, deleted, and untracked non-ignored worktree changes, matching `git add -A` semantics.
- Inspect all changes before staging. If they contain likely secrets, credentials, private keys, generated user data, or clearly unrelated work, stop and ask instead of committing or silently excluding files.
- Keep Git commands non-interactive. Never reset, amend, rebase, delete branches, force-push, or discard working-copy changes as part of this workflow.
- Preserve successful state when a later step fails. Do not roll back a created branch, commit, push, or pull request automatically.

## Workflow

1. Resolve the repository root with `git rev-parse --show-toplevel` from the active project and use the canonical root for every following command. Stop if the location is not a Git worktree.
2. Inspect repository instructions and current state before mutation:
   - Run `git status --porcelain=v1 --untracked-files=all`; stop with `The worktree has no changes to submit` when it is empty.
   - Inspect staged, unstaged, and untracked changes closely enough to identify scope and sensitive content.
   - Stop during an unfinished merge, rebase, cherry-pick, or revert.
   - Verify `origin`, GitHub CLI authentication, and repository access before creating the branch or commit.
   - Run repository-mandated pre-commit validation when instructions define it. Stop before Git mutation if required validation fails.
3. Read the current branch with `git branch --show-current`:
   - Reuse it when its name begins with `submit-pr/`.
   - Otherwise create and switch to `submit-pr/YYYYMMDD-HHMMSS`, using the current local time and `git switch -c`.
4. Stage the complete worktree with `git add -A`. Confirm `git diff --cached --name-only` is non-empty, then inspect the complete cached diff and diffstat.
5. Write exactly one Conventional Commit subject describing the staged diff:
   - Allow only `feat`, `fix`, `refactor`, `docs`, `test`, `chore`, `build`, `ci`, `perf`, or `style`.
   - Allow an optional lowercase alphanumeric scope containing `.`, `_`, or `-`, plus an optional breaking-change `!`.
   - Use the form `type(scope)!: summary`, omit unused optional parts, exclude control characters and Markdown, and keep the full line at 120 characters or fewer.
   - Use optional invocation context only to disambiguate intent already visible in the diff.
6. Commit with `git commit -m SUBJECT`, then record the full commit ID from `git rev-parse HEAD`. Recheck the worktree; if hooks or generators left changes behind, stop before pushing and report that the commit does not contain all current changes.
7. Push with `git push --set-upstream origin BRANCH` and do not use force options.
8. Write the pull request body from the committed diff and optional context. Return plain Markdown with a concise `## Summary` section, no surrounding prose, and no code fence. Use the commit subject as the pull request title.
9. Check for an existing open pull request for the branch before creating another. If none exists, run `gh pr create --head BRANCH --title SUBJECT --body BODY`. Require an HTTP(S) pull request URL from `gh`; after an ambiguous failure, query the branch again before retrying so duplicate pull requests are not created.
10. Report completion with the branch, full commit ID, and pull request URL.

## Failure Reporting

- Stop at the first failed precondition, command, commit-message validation, or empty pull request body.
- Report `Submit PR stopped`, the failed step and concise sanitized error output, the branch when known, and the commit ID or `not created`.
- Never include credentials or sensitive diff contents in the report.
- State which durable actions already succeeded and provide the smallest safe continuation step. Do not claim the workflow completed unless the push and pull request URL are both verified.
