---
name: personal-knowledge-base
description: Search and maintain Jamie's personal knowledge repository at `/home/jamie/opt/org-root`. Use implicitly whenever the user asks about their own notes, prior knowledge, research memory, org-roam/deft/journal/project records, "知识库", "笔记", "我之前有没有写过", "帮我查一下以前的记录", asks to save, remember, capture,整理,沉淀,归档, or organize material into the knowledge base, or asks to summarize a git repository into org-roam with phrases like "summarize this repo", "create org-roam summary", or "generate repo summary". Supports reading, summarizing, linking, appending to existing Org notes, creating new Org-roam/project/journal/deft notes, and generating repository summary notes.
---

# Personal Knowledge Base

Use `/home/jamie/opt/org-root` as Jamie's personal Org knowledge repository.

## Repository Shape

- `projects/`: active project hubs, plans, tasks, and status logs.
- `roam/`: long-lived knowledge notes, literature cards, and topic notes.
- `deft/`: quick captures, drafts, and temporary notes.
- `journal/`: dated daily or monthly logs.
- `pdf/`, `roam/img/`, and `deft/img/`: attachments; do not modify unless the request is explicitly about assets.

Always read `/home/jamie/opt/org-root/AGENTS.md` before writing in the knowledge repository. Check for a more specific nested `AGENTS.md` before editing any nested workspace such as `external/`.

## Query Workflow

1. Translate the user's request into 2-6 concrete search terms. Include bilingual variants when useful, especially for research terms.
2. Run the bundled search helper from this skill directory:

   ```sh
   python3 scripts/kb_search.py search "query terms"
   ```

   If running from outside this skill directory, resolve `scripts/kb_search.py` relative to this `SKILL.md`.
3. Read the top matching files before answering. Prefer narrow reads around relevant headings or snippets.
4. If the first search is sparse or noisy, rerun with alternate terms, acronyms, Chinese/English variants, paper keys, project names, or filenames.
5. Ground the answer in the notes found. Cite local paths and line numbers when possible.
6. Do not dump private note contents wholesale. Summarize and quote only the small fragments needed to answer.

Search defaults intentionally skip `.git`, `.agent-shell`, `.agents`, `.codex`, generated caches, binary attachment folders, and `external/`. Include `external/` only when the user asks about an external paper/workspace or no in-repo note answers the question.

## Capture Workflow

Treat requests such as "帮我把 ... 整理到知识库", "记一下", "沉淀成笔记", "整理到笔记里", "save this to my notes", or "add this to the knowledge base" as permission to edit the knowledge repository. Do not ask for confirmation unless the target is ambiguous in a way that could misfile important private knowledge, the request would delete/rename content, or the edit would touch many files.

1. First search for existing related notes:

   ```sh
   python3 scripts/kb_search.py suggest "raw topic or source text"
   ```

2. Choose the write target:
   - Append to an existing `roam/` note when the note is clearly the same durable concept, paper, technique, or topic.
   - Append to `projects/*.org` when the content is a project plan, task, design decision, review, status update, or implementation note for an active project.
   - Append to `journal/YYYYMM01.org` when the content is a dated event, meeting note, daily record, or time-bound capture. Use the current absolute date for headings.
   - Create a new `roam/YYYY-MM-DDtHHMM.org` note when the content is durable knowledge and no strong existing note exists.
   - Use `deft/YYYY-MM-DDtHHMM.org` only for rough inbox captures, drafts, or content the user explicitly describes as temporary.
3. Read the chosen target before editing. Preserve existing Org metadata, heading style, and human-authored wording.
4. Write concise, reusable Org content:
   - Prefer one topic per file.
   - Use headings for structure rather than long flat paragraphs.
   - Convert raw chat into durable wording: context, key points, decisions, open questions, and links.
   - Add backlinks or `[[file:...][title]]` links to obviously related notes when discovered during search.
   - Avoid inventing unsupported facts. Mark uncertainty explicitly.
5. For a new `roam/` note, use this shape:

   ```org
   :PROPERTIES:
   :ID:       <uuid>
   :END:
   #+title: <concise title>
   #+filetags: :tag1:tag2:

   <organized note content>
   ```

6. After writing, answer with the edited path and a short summary of what changed.

## Repo Summary Workflow

When the user explicitly asks to summarize a git repository into org-roam, read `references/repo-summary.md` and follow that workflow. Use it for requests such as:

- "Summarize this repo"
- "Create an org-roam summary for this repository"
- "Generate a repo summary"
- "Add this repo to my org-roam notes"

Do not trigger repo-summary mode for ordinary repository understanding questions.

## Helper Script

`scripts/kb_search.py` provides:

- `search QUERY`: rank matching Org/Markdown/text files and show titles plus snippets.
- `suggest TEXT`: search using extracted terms and print likely existing targets plus a new-note fallback.
- `recent`: list recently modified notes.

Use `--root /path/to/org-root` only when the knowledge root differs from `/home/jamie/opt/org-root`.
