# CONTEXT.md Format

## Structure

```md
# {Context Name}

{One or two sentences describing what this context is and why it exists.}

## Language

**Order**:
{A one- or two-sentence definition of the term.}
_Avoid_: Purchase, transaction

**Invoice**:
A request for payment sent to a customer after delivery.
_Avoid_: Bill, payment request
```

## Rules

- Be opinionated. Pick one canonical term and list its alternatives under `_Avoid_`.
- Keep definitions to one or two sentences. Define what a concept is, not what it does.
- Include only project-specific domain concepts, not general programming concepts.
- Group terms under subheadings when natural clusters emerge; otherwise keep a flat list.

## Single- and multi-context repositories

Use one `CONTEXT.md` at the repository root for a single context.

For multiple contexts, use a root `CONTEXT-MAP.md` that links to each context and records their relationships:

```md
# Context Map

## Contexts

- [Ordering](./src/ordering/CONTEXT.md) — receives and tracks customer orders
- [Billing](./src/billing/CONTEXT.md) — generates invoices and processes payments

## Relationships

- **Ordering → Billing**: Ordering emits `OrderPlaced`; Billing consumes it to prepare payment
```

Infer the structure from the repository:

- If `CONTEXT-MAP.md` exists, read it and update the relevant context.
- If only a root `CONTEXT.md` exists, treat the repository as a single context.
- If neither exists, create a root `CONTEXT.md` lazily when the first term is resolved.
