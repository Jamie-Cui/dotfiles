---
name: wayfinder
description: Plan an effort too large for one agent session as a shared map of decision tickets, then resolve tickets one at a time until the route to the destination is clear. Use only when the user explicitly invokes `$wayfinder` with a large, uncertain effort or an existing Wayfinder map; do not trigger for ordinary implementation plans or TODO lists.
---

# Wayfinder

Turn a large, uncertain effort into a durable map on the repository's issue tracker. Treat tickets as questions whose resolutions are decisions, not slices of implementation work.

## Core Rules

1. Plan by default. Produce decisions rather than destination deliverables unless the map's Notes explicitly include execution.
2. Name the destination before charting tickets. Define the spec, decision, or change that marks the effort complete.
3. Refer to maps and tickets by linked title in human-facing text, never by a bare number or slug.
4. Keep each decision in exactly one ticket. Let the map index closed tickets with one-line gists and links without duplicating their detail.
5. Resolve at most one non-research ticket per session.
6. Expect concurrent sessions. Claim a ticket before working on it and re-read tracker state before mutating it.

## Tracker Selection

Use the issue tracker named by the user or configured for the repository. Prefer its available connector or CLI; for GitHub repositories, use an available GitHub connector or `gh`. Before creating or changing remote issues, show the intended map and ticket structure and obtain user approval unless the invocation already explicitly requests those tracker mutations.

Use native child-issue and blocking relationships when the available tracker interface supports them. Otherwise encode the relationships in issue bodies with stable linked-title lists. If no tracker is available, ask whether to use a local Markdown map and agree on its path before creating it.

Use these labels:

- `wayfinder:map` for the map
- `wayfinder:research` for research tickets
- `wayfinder:prototype` for prototype tickets
- `wayfinder:grilling` for discussion tickets
- `wayfinder:task` for prerequisite-work tickets

## Map Format

Create one canonical map issue with this body:

```markdown
## Destination

<One or two lines describing the spec, decision, or change at the end of the route.>

## Notes

<Domain, skills to consult, execution override, and standing preferences.>

## Decisions so far

- [<closed ticket title>](link): <one-line gist of its resolution>

## Not yet specified

<In-scope questions that are visible but not yet precise enough to ticket.>

## Out of scope

<Work explicitly ruled beyond the destination, with reasons.>
```

Do not list open tickets in the map when the tracker can query child issues. When it cannot, add an `## Open tickets` section containing linked titles and explicit `Blocked by` relationships.

## Ticket Format

Create each ticket as a child of the map when supported, sized for one agent session:

```markdown
## Question

<The decision or investigation this ticket resolves.>
```

Claim a ticket by assigning it to the person driving the map. Treat an open, unassigned ticket as unclaimed. A ticket is unblocked when every ticket blocking it is closed; the frontier is the set of open, unblocked, unclaimed tickets.

Record the answer in a resolution comment rather than rewriting the question. Link assets created during resolution instead of pasting large artifacts into the ticket.

## Ticket Types

- **Research (AFK):** Inspect documentation, APIs, repositories, or knowledge bases to surface facts needed by a decision. Use parallel subagents when available and safe; otherwise research in the current session. Resolve with evidence, sources, and the resulting facts.
- **Prototype (HITL):** Create a cheap, rough artifact that makes a behavior or appearance decision concrete. Ask the human to react before resolving it.
- **Grilling (HITL):** Work through a decision in conversation. Invoke `$grill-me` when available, asking one question at a time and letting the human speak for themselves.
- **Task (HITL or AFK):** Complete prerequisite work that must happen before a decision can be made. Use this only to unblock a decision, not to implement the destination.

Never simulate the human side of a HITL ticket. Drive AFK tasks directly where authorized; otherwise provide a precise checklist and wait for the result.

## Fog of War

Keep the map deliberately incomplete. Put an item in `Not yet specified` when it is in scope but its question cannot yet be stated precisely. Create a ticket as soon as the question is sharp, even if it is blocked or currently unanswerable.

After resolving a ticket, graduate newly precise fog into tickets and remove the corresponding text from `Not yet specified`. Do not duplicate decided questions, live tickets, or out-of-scope work there.

Treat out-of-scope findings as boundaries, not decisions. Close a mis-scoped ticket and add a linked one-line explanation under `Out of scope`; do not add it to `Decisions so far`.

## Chart a Map

When the user invokes `$wayfinder` with a loose idea:

1. Inspect the repository for facts that should not be asked of the user.
2. Use `$grill-me` when available to settle the destination and scope one question at a time.
3. Explore breadth-first across the effort to identify sharp decisions, dependencies, and visible fog.
4. Stop and ask how to proceed if the whole route fits comfortably in one session and no fog remains.
5. Draft the map, immediately specifiable tickets, ticket types, and blocking edges.
6. Obtain approval for external tracker mutations, then create the map and tickets before wiring relationships.
7. Start independent research tickets in parallel only when suitable tooling is available and the work needs no further authority.
8. Stop after charting; do not hand-resolve a decision ticket in the same session.

## Work Through a Map

When the user invokes `$wayfinder` with a map URL or identifier:

1. Load the map as the low-resolution orientation without opening every ticket.
2. Use the named ticket, or select the first frontier ticket in tracker order.
3. Claim it before investigation or discussion.
4. Load related tickets only as needed and invoke skills named in the map's Notes.
5. Resolve the ticket through the appropriate research, prototype, grilling, or task workflow.
6. Post the resolution, close the ticket, and append its linked one-line gist to `Decisions so far`.
7. Create newly surfaced tickets, wire blocking edges, graduate clarified fog, and close anything newly shown to be out of scope.
8. Re-read the map and frontier to account for concurrent changes before reporting the result.

Adapted from Matt Pocock's Wayfinder skill: https://github.com/mattpocock/skills/blob/main/skills/engineering/wayfinder/SKILL.md
