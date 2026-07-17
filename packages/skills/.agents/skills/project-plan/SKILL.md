---
name: project-plan
description: Manage plans, TODO/PROJ items, deadlines, notes, and summaries in the central project org file, usually `project.org`. Use only when the user explicitly invokes `$project-plan`; never trigger implicitly from planning language, the presence of a plan or project org file, or a request to create, review, or update a plan. If invoked without any follow-up prompt, switch to plan mode, list the current active plans, and ask the user which one to execute or review.
---

# Project Plan

Treat the project's central org file as the source of truth for project plans, deadlines, notes, and summaries.

## Working Rules

1. Run this workflow only after the user explicitly invokes `$project-plan`. Do not infer invocation from planning language or project context.
2. Resolve the active project root first. Prefer the live Emacs project context over guessing from filesystem paths.
3. Resolve the central project org file next. Prefer `(+org-project-current-file)` or `(+org-project-file-dwim)` when available. If no helper is available, fall back to `project.org` in the active project root.
4. When the resolved file is `project.org`, detect whether the project root uses version control. If it does, add the project-relative file to the backend's standard ignore file before creating or writing it. Preserve existing ignore rules, avoid duplicate entries, and verify that the backend reports the file as ignored.
5. If `project.org` is already tracked, an ignore rule is insufficient. Stop tracking it with the backend-specific operation that preserves the working copy (for Git, `git rm --cached -- project.org`), never delete the local org file, and verify the resulting state.
6. Read before writing. For planning or review work, inspect the active task headings plus `* Note` and any active project subtree. For note-only requests, read `* Note` first and ignore task sections unless they are directly relevant.
7. Treat an explicit `$project-plan` invocation with no follow-up prompt as a request to enter plan mode. Enumerate the active `PROJ`, `TODO`, `WAIT`, and imminent deadline items from the project org file, then ask the user which item to execute, continue, or review.
8. Treat an explicit `$project-plan` invocation with follow-up text as an update request. Classify the content before editing: actionable work belongs in plan/task headings, while non-actionable facts, notes, and summaries belong under `* Note`.
9. Write agreed plans into the project org file instead of leaving them only in chat. When the user asks to make or refine a plan, convert the outcome into org entries that match the existing file structure.
10. Represent multi-step efforts as `PROJ` entries with child `TODO` or `WAIT` items when that matches the existing file. Add `DEADLINE:` when a due date is known.
11. Update the corresponding org entries after technical discussion changes the plan. Adjust task state, wording, order, deadlines, or notes so the file stays current after review.
12. Mark completed work as `DONE` when execution finishes. Do not leave finished plan items open unless the user explicitly wants to defer that update.
13. Keep remembered facts, design notes, meeting notes, and summaries under `* Note` unless they are actionable tasks. Do not silently convert note content into TODO items.
14. Preserve human-authored task wording when possible. Apply the authorship-tag invariant below to every actionable heading created or substantially rewritten by the agent.
15. Do not silently delete human-captured tasks. Close, rewrite, or archive them only when the conversation or the existing org workflow supports that change.

## Authorship-Tag Invariant

- Add the Org tag `:agent:` when creating a `PROJ`, `TODO`, or `WAIT` heading whose wording or decomposition the agent generated, even when it implements a user-requested plan.
- Add `:agent:` during the initial write and preserve every existing tag. Do not wait for the user to identify a missing tag.
- For a generated `PROJ` subtree, place `:agent:` on the parent and rely on inheritance only after verifying `org-use-tag-inheritance` is enabled. Otherwise add `:agent:` to each generated actionable child.
- Treat verbatim user-captured task wording as human-authored and follow the file's existing human-authorship convention instead of adding `:agent:` automatically.
- Before reporting a plan update complete, re-read the affected subtree and verify that every generated actionable heading has an explicit or effective inherited `:agent:` tag.

## Preferred Helpers

Use Emacs helpers when available instead of hand-editing headings:

- `(+org-project-current-file)` to locate the current project's central file
- `(+org-project-file-dwim)` to detect or choose a project file
- `(+org-project-append-log FILE TEXT)` to append project log entries
- `(+org-project-archive-done-task)` when the user explicitly asks to archive completed work
- `(vc-responsible-backend PROJECT-ROOT)` to detect whether a VC backend manages the project
- `vc-ignore` with `default-directory` bound to `PROJECT-ROOT`, passing the project-relative file, to add the central file to that backend's ignore rules

When no dedicated helper exists for plan maintenance, edit the relevant subtree directly and keep the surrounding structure intact.

## Content Conventions

- Treat the project org file as the system of record for plans, deadlines, notes, and summaries
- Prefer `project.org` when no project-specific helper or existing org file says otherwise
- Prefer updating the existing heading layout over inventing a new schema
- Use `PROJ` for multi-step efforts and child `TODO` or `WAIT` items for concrete next actions
- Use `DEADLINE:` for due dates
- Use `* Note` for non-actionable notes and end-of-task summaries
- Use `* Log` for agent-generated status updates only when that section already exists or the workflow clearly expects it
- Use `:agent:` for agent-generated actionable headings, following the authorship-tag invariant
- Keep human-captured tasks tagged as human-authored when the file already uses those tags or properties

## Core Workflow

1. Resolve the central file; when it is `project.org` in a version-controlled project, ensure it is ignored and untracked without removing the working copy.
2. If the skill is invoked without follow-up text, enter plan mode, summarize the active plans, and ask the user to choose one path before making changes.
3. If the skill is invoked with follow-up text, classify the request as plan/task work or note/summary work and update the correct section of the project org file.
4. Write or revise the plan in the project org file after the user and agent agree on the work, adding `:agent:` to generated actionable headings as they are created.
5. Reflect technical review outcomes back into the matching org entries instead of keeping updated intent only in chat.
6. Mark completed items as `DONE` when the implementation or investigation finishes.
7. Re-read the affected subtree and verify effective authorship tags before reporting the update complete.
8. Append a short summary or note under `* Note` when the result is worth remembering but is not itself a task.

## Good Patterns

- Call `$project-plan` alone, list the current active plans from the project org file, and let the user choose which one to execute next
- Turn a chat-level implementation plan into a `PROJ ... :agent:` subtree with concrete child tasks in the project file before or while starting the work
- Update an existing `PROJ` subtree after scope, sequencing, or deadlines change during discussion
- Mark the finished `TODO` or `PROJ` entry as `DONE` after the work lands
- Add a short post-work summary under `* Note` when the user wants a durable record of the outcome
- Keep `Archive` folded and out of the active working set unless the task is explicitly about cleanup or review
