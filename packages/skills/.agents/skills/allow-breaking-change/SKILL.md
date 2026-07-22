---
name: allow-breaking-change
description: Activate a session-wide policy that permits architecturally justified breaking changes and removes compatibility with project-owned historical interfaces from design constraints. Use only when the user explicitly invokes `$allow-breaking-change`; never trigger implicitly from generic refactoring, simplification, architecture, compatibility, or breaking-change discussion. Keep the policy active across projects and tasks for the rest of the current conversation unless the user overrides it for a task or disables it.
---

# Allow Breaking Change

Treat compatibility with project-owned historical behavior as optional for the rest of the current conversation. Prefer the simplest sound architecture for current requirements; do not break behavior merely for novelty.

## Activate and Retain the Policy

1. Activate only after an explicit `$allow-breaking-change` invocation.
2. For a bare invocation, confirm activation and its data-protection boundary in one concise sentence, then wait for a task. For an invocation with a task, activate first and then handle the task.
3. Apply the policy across projects and tasks, including planning, design, review, diagnosis, and implementation, until the conversation ends or the user explicitly disables it.
4. Treat a clear task-level instruction such as `keep compatibility for this task` as a temporary override. Treat a clear instruction such as `disable allow-breaking-change` as revocation for the rest of the conversation.
5. Mention the active policy only when compatibility affects a decision or result. Do not repeat a status reminder on unrelated turns.
6. Continue to obey higher-priority instructions, repository requirements, and explicit current-task constraints.

## Make Decisions Without Historical Compatibility

- Exclude backward and forward compatibility with project-owned legacy APIs, CLIs, configuration, protocols, and file formats from the decision criteria.
- Do not add adapters, deprecation periods, parallel implementations, version bridges, or legacy parsing solely to preserve historical consumers.
- Update all in-scope callers, tests, documentation, examples, and generated artifacts to the new contract.
- Classify old tests by intent. Remove or rewrite assertions that exist only for compatibility; retain requirements for correctness, security, data integrity, accessibility, and current behavior.
- Still weigh implementation effort, regression risk, validation difficulty, performance, and operational risk. Permission to break compatibility is not permission to expand task scope or perform destructive actions.
- Continue to honor external standards, platform ABIs, active third-party contracts, and other interoperability requirements that remain part of the current task.

## Judge Architecture with KISS and Unixify

For material changes to responsibility boundaries, interfaces, data representations, or system layers, apply the installed `$kiss` skill first to remove unnecessary concepts and mechanisms, then apply `$unixify` to shape the remaining responsibilities, representations, and composition interfaces. Skip this extra workflow for local mechanical changes.

Override only the compatibility-preservation guardrails in KISS and Unixify while this policy is active. Preserve their other guardrails, especially correctness, security, data integrity, clarity, justified boundaries, and observable failure behavior.

## Protect Data and Operations

- When stored data must move to an incompatible representation, provide and verify a one-way, lossless migration. Support only the new representation after migration.
- If a lossless migration is impossible, stop and report the information or semantics that would be lost. Obtain a task-specific decision before performing a lossy migration.
- Introduce a temporary compatibility bridge only when a current availability or rolling-deployment requirement makes mixed-version operation necessary. Give the bridge an explicit removal condition and remove it after the transition.

## Communicate Breaking Changes

Do not request permission merely because the selected design is breaking. Briefly identify the major broken contracts, affected callers or data, required migration, and verification performed in the plan, review, or completion report.
