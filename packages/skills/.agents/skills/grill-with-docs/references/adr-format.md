# ADR Format

Store ADRs in `docs/adr/` with sequential names such as `0001-event-sourced-orders.md`. Create the directory only when the first ADR is needed.

## Template

```md
# {Short title of the decision}

{In one to three sentences, state the context, the decision, and why it was made.}
```

Keep the record as short as the decision allows. Add optional material only when it preserves useful context:

- Add status frontmatter (`proposed`, `accepted`, `deprecated`, or `superseded by ADR-NNNN`) when a decision may be revisited.
- Add considered options when the rejected alternatives are worth remembering.
- Add consequences when non-obvious downstream effects need to be explicit.

Scan the target ADR directory for the highest existing number and increment it by one.

Good ADR subjects include architectural shape, integration patterns between contexts, technology choices with meaningful lock-in, boundary and ownership decisions, deliberate deviations from the obvious approach, constraints invisible in code, and non-obvious rejected alternatives.
