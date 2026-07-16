---
name: project-summary
description: Generate comprehensive org-roam summaries of git repositories. Use when the user explicitly asks to "summarize this repo", "create org-roam summary", "generate repo summary", or similar requests. Analyzes code architecture, purpose, dependencies, and design patterns, then creates or updates an org-roam note in the user's org-roam directory.
---

# Project Summary to Org-Roam

This skill performs deep analysis of a git repository and generates a comprehensive org-roam note summarizing its architecture, purpose, and key components.

## When to Use

Trigger this skill ONLY when the user explicitly requests:
- "Summarize this repo"
- "Create an org-roam summary for this repository"
- "Generate a repo summary"
- "Add this repo to my org-roam notes"

Do NOT trigger for general understanding questions or exploratory tasks.

## Overview

The workflow:
1. Detect org-roam directory from Emacs configuration
2. Check if summary already exists and whether repo has changed
3. Perform comprehensive codebase analysis
4. Generate or update org-roam note with findings

## Step 1: Detect Org-Roam Directory

Read the user's Emacs configuration to find `org-roam-directory`. Check these locations in order:

1. `~/.emacs.d/init.el`
2. `~/.emacs`
3. `~/.config/emacs/init.el`

Look for patterns like:
```elisp
(setq org-roam-directory "~/path/to/org-roam")
(setq org-roam-directory (expand-file-name "org-roam" "~"))
```

If not found, ask the user for the org-roam directory path.

## Step 2: Check Existing Summary

Determine the repo name from the current directory (use `basename $(pwd)`).

Check if `{org-roam-dir}/{repo-name}-summary.org` exists:

**If file exists:**
1. Read the file and extract the `LAST_ANALYZED_COMMIT` property
2. Get current HEAD commit: `git rev-parse HEAD`
3. Compare commits:
   - If same: inform user summary is up-to-date, ask if they want to regenerate anyway
   - If different: proceed with analysis and update

**If file doesn't exist:**
- Proceed with analysis and create new file

## Step 3: Comprehensive Repository Analysis

Perform deep analysis covering all these aspects:

### 3.1 Documentation and Purpose
- Read README, CONTRIBUTING, LICENSE files
- Extract project purpose, goals, and use cases
- Identify target audience and key features

### 3.2 Project Structure
- Map directory organization using `find` or `Glob`
- Identify module boundaries and component organization
- Note configuration files and their purposes

### 3.3 Code Architecture
- Identify entry points (main files, CLI commands)
- Map core classes, functions, and interfaces
- Trace key execution paths
- Document major abstractions and their relationships

### 3.4 Dependencies
- Parse dependency files (package.json, requirements.txt, Cargo.toml, go.mod, etc.)
- Identify external libraries and their roles
- Note build tools and development dependencies

### 3.5 Design Patterns and Conventions
- Identify architectural patterns (MVC, microservices, plugin system, etc.)
- Note coding conventions and style
- Document key design decisions visible in the code

### Analysis Approach

Use a combination of tools to gather information efficiently:
- `Glob` to discover files and understand structure
- `Grep` to search for patterns, imports, and key definitions
- `Read` to examine critical files in detail
- `Bash` for git operations and dependency parsing

Focus on understanding the "why" behind the architecture, not just listing files. Trace how components interact and what problems the design solves.

## Step 4: Generate Org-Roam Note

Create or update the org-roam file with this structure:

```org
:PROPERTIES:
:ID: [generate UUID using uuidgen or similar]
:LAST_ANALYZED_COMMIT: [current git HEAD commit hash]
:REPO_PATH: [absolute path to repository]
:END:
#+title: [Repository Name] Summary
#+date: [YYYY-MM-DD]

* Overview

[Brief description of what this repository does and its primary purpose]

* Architecture

** Project Structure

[Directory organization and module layout]

** Core Components

[Key classes, modules, or subsystems and their responsibilities]

** Entry Points

[Main files, CLI commands, or API endpoints]

* Dependencies

[External libraries and tools, organized by category if applicable]

* Design Patterns

[Architectural patterns, coding conventions, and key design decisions]

* Key Insights

[Important observations about the codebase that would help someone understand or work with it]
```

### File Naming

Use the pattern: `{repo-name}-summary.org` where `{repo-name}` is derived from `basename $(pwd)`.

### Metadata Fields

- **:ID:**: Generate a unique UUID for org-roam node identification
- **:LAST_ANALYZED_COMMIT:**: Current HEAD commit hash for change detection
- **:REPO_PATH:**: Absolute path to help locate the repository later
- **#+title**: Human-readable title
- **#+date**: ISO format date (YYYY-MM-DD)

## Step 5: Write the File

Use the `Write` tool to create or overwrite the org-roam file at the detected path.

After writing, inform the user:
- Where the file was saved
- Whether it was created new or updated
- The commit hash that was analyzed

## Important Notes

### Change Detection Logic

When updating an existing file:
1. Extract `LAST_ANALYZED_COMMIT` from the existing file
2. Compare with current `git rev-parse HEAD`
3. If commits differ, the repo has changed - proceed with update
4. Update the `LAST_ANALYZED_COMMIT` property with the new commit hash

### Analysis Depth

This is a comprehensive deep-dive analysis. Take time to:
- Read multiple files to understand patterns
- Trace execution flows, not just list files
- Explain the "why" behind architectural decisions
- Identify what makes this codebase unique or interesting

### Writing Style

The org-roam note should be:
- **Informative**: Help someone understand the codebase quickly
- **Structured**: Use clear headings and logical organization
- **Insightful**: Go beyond surface-level observations
- **Concise**: Dense with information, but not verbose

Avoid simply listing files or functions. Instead, explain how components work together and what problems they solve.

### Error Handling

If org-roam directory cannot be detected:
- Ask the user to provide the path
- Suggest common locations: `~/org-roam`, `~/Documents/org-roam`, `~/Dropbox/org-roam`

If not in a git repository:
- Inform the user this skill requires a git repository
- Cannot track changes without git commit hashes

## Example Usage

User: "Summarize this repo"

Response flow:
1. Detect org-roam directory from Emacs config
2. Check if `{repo-name}-summary.org` exists and compare commits
3. Perform comprehensive analysis of the codebase
4. Generate or update the org-roam file
5. Report completion with file location
