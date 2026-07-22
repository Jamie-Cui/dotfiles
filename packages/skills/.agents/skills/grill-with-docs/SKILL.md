---
name: grill-with-docs
description: Relentlessly interview the user to sharpen a plan or design against the project's domain model while updating its glossary and architectural decision records. Use when the user wants to stress-test a plan against existing code, terminology, CONTEXT.md, or ADRs and keep those documents current as decisions crystallize.
---

# Grill with Docs

Interview the user relentlessly about every aspect of the plan or design until reaching shared understanding. Walk down each branch of the decision tree and resolve dependencies between decisions one by one. Provide a recommended answer with every question.

Ask one question at a time and wait for feedback before continuing. If a fact can be found by exploring the environment, look it up instead of asking. Leave decisions to the user and wait for their answer.

Do not implement the plan until the user confirms that shared understanding has been reached.

## Ground the session

Explore the codebase before and during questioning. Look for existing domain documentation as well as implementation evidence.

Treat a root `CONTEXT.md` as the glossary for a single-context repository. If `CONTEXT-MAP.md` exists, read it to locate the relevant bounded context, its `CONTEXT.md`, and its ADR directory. Infer which context the current topic belongs to; ask only when the repository cannot answer.

Create documentation lazily:

- Create `CONTEXT.md` only when the first domain term is resolved.
- Create `docs/adr/` only when the first qualifying ADR is accepted.
- In a multi-context repository, write context-specific terms and decisions beside that context; keep system-wide decisions in the root ADR directory.

## Sharpen the domain model

During the session:

- Challenge terminology that conflicts with the existing glossary.
- Replace vague or overloaded language with a precise canonical term.
- Test domain relationships with concrete scenarios and edge cases.
- Cross-reference claims with the code and surface contradictions immediately.

When a term is resolved, update the relevant `CONTEXT.md` immediately instead of batching changes. Keep it strictly as a domain glossary, with no implementation details, specification notes, or scratch work. Read [references/context-format.md](references/context-format.md) before creating or editing it.

## Offer ADRs sparingly

Offer to create an ADR only when the decision is all three of the following:

1. Hard to reverse, with a meaningful cost to changing it later.
2. Surprising without context, so a future reader would wonder why it was made.
3. The result of a real trade-off between genuine alternatives.

Skip the ADR if any condition is missing. After the user accepts the offer, read [references/adr-format.md](references/adr-format.md) before writing it.
