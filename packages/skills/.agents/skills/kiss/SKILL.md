---
name: kiss
description: Apply the KISS principle to reduce accidental complexity while preserving required behavior. Use when the user asks to simplify a design, plan, implementation, API, workflow, or explanation; requests the smallest viable solution; wants to avoid overengineering; or needs a review for premature abstraction, speculative extensibility, unnecessary layers, options, dependencies, or moving parts.
---

# KISS

Find the simplest solution that fully satisfies the current requirements. Optimize for fewer concepts, decisions, and moving parts—not merely fewer lines of code.

## Simplify

1. State the essential outcome and non-negotiable constraints.
2. Separate current requirements from guesses about future needs.
3. Identify complexity that has no present justification: extra layers, parallel mechanisms, premature abstractions, configuration, dependencies, state, or indirection.
4. Prefer, in order:
   - Remove unnecessary work.
   - Reuse an existing convention or mechanism.
   - Implement the behavior directly and locally.
   - Add a small abstraction only when demonstrated repetition or variation justifies it.
5. Recommend or implement the simplest sufficient option. Name what was removed or deferred and why.
6. Run the smallest meaningful check that confirms the required behavior still holds.

## Guardrails

- Preserve correctness, security, data integrity, compatibility, accessibility, and required observability.
- Do not confuse compact code with a simple system. Prefer clarity over cleverness.
- Do not rewrite stable code when the migration cost and risk exceed the complexity removed.
- Do not collapse meaningful domain distinctions or merely hide complexity behind an abstraction.
- Add the next-smallest mechanism only when evidence shows the simpler approach is insufficient.
- When several options work, recommend the simplest one and state the concrete condition that would justify a more complex alternative.

## Communicate the Result

Lead with the simplified recommendation or change. Briefly report the constraints retained, complexity removed or deferred, assumptions made, and verification performed.
