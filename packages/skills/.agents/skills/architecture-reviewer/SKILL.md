---
name: architecture-reviewer
description: Review an existing software architecture end to end for evidence-backed problems in boundaries, state, lifecycles, interfaces, failure behavior, security, persistence, performance, testability, redundancy, and unjustified complexity. Use for architecture reviews, system-wide structural audits, or simplification assessments beyond a code diff. Do not use for ordinary patch review or implementation.
---

# Architecture Reviewer

Perform a read-only, evidence-first architecture review. Find consequential
architectural problems, recommend the simplest sound target design, and leave
implementation to a separately authorized task.

## Keep the Review Boundary

- Do not edit the reviewed product, its documentation, configuration, tests, or
  generated artifacts. Do not post review comments externally.
- Read implementations, callers, tests, project instructions, architecture
  documents, ADRs, history, and runtime evidence needed to establish facts.
- Run focused diagnostics or tests when they materially resolve a hypothesis.
  Report exactly what ran and do not claim unexecuted checks passed.
- Follow the scope the user named. A repository-wide claim requires
  repository-wide coverage; otherwise label the result as a scoped review.
- Treat repository instructions and current requirements as constraints. Treat
  architecture documents and comments as claims to verify against code, not as
  proof of actual behavior.

## Apply KISS and Unixify

Use the installed `$kiss` skill first to remove concepts and mechanisms without
a present justification. Then use `$unixify` to evaluate the responsibilities,
representations, module depth, dependency direction, composition contracts,
and failure behavior that remain. This skill owns the evidence and finding
protocol; do not duplicate or weaken those design heuristics here.

Do not equate simplicity with fewer files or lines. A large module can be a
valuable deep module when its small interface localizes necessary complexity.
A split is useful only when the separated parts vary, fail, are secured, are
reused, are tested, or are owned independently.

## Handle Breaking Changes Deliberately

Preserve published contracts by default. When the user explicitly permits
breaking changes for the current task, or an active session policy already does
so, remove compatibility with project-owned historical interfaces from the
decision criteria. Do not add adapters, dual implementations, legacy parsing,
or deprecation periods solely for that compatibility.

Breaking-change permission does not relax correctness, security, data
integrity, accessibility, operational safety, external standards, platform
ABIs, or active third-party contracts. Identify affected callers, tests,
documentation, stored data, and deployment steps. Require a verified lossless
migration for incompatible stored data; stop for a user decision if loss would
be unavoidable.

## Establish Coverage Before Conclusions

For any review:

1. Resolve the review scope, current requirements, non-negotiable constraints,
   published behavior, and compatibility posture.
2. Inspect the implementation and its real callers before judging a proposed
   boundary or abstraction.
3. Trace each candidate issue through tests, documentation, history, and
   runtime evidence as relevant. Use recent churn to find likely hot spots, not
   as proof that a design is wrong.
4. Distinguish observed facts, supported inferences, and unverified hypotheses.
5. Use the smallest meaningful verification that could confirm or falsify each
   material claim.

For a repository-wide review, first build a coverage inventory of:

- modules and dependency direction;
- public APIs, protocols, commands, configuration, and extension seams;
- canonical data models, state machines, registries, queues, caches, and
  persistence stores;
- ownership of initialization, execution, completion, cancellation, cleanup,
  and recovery;
- trust, permission, process, network, and resource boundaries;
- representative end-to-end success, failure, interruption, and resume paths;
- tests and documented architectural invariants;
- recent high-churn or repeatedly repaired subsystems.

Do not claim comprehensive coverage until this inventory has been reconciled
with the inspected evidence. List every material coverage gap.

When subagents are available, use them only for a broad review that benefits
from independent bounded lanes. The lead reviewer first establishes the common
system map, then assigns non-overlapping concerns or subsystems such as
state/lifecycle, interfaces/dependencies, or security/persistence. The lead
must independently validate evidence, deduplicate findings, and normalize
severity. Keep scoped reviews single-agent unless a concrete split adds value.

## Examine the Whole Architecture

Check for problems in:

- responsibility ownership, module boundaries, cohesion, and locality;
- dependency direction, cycles, pass-through layers, and leaky abstractions;
- canonical data models, duplicated knowledge, state transitions, and sources
  of truth;
- control flow, asynchronous lifecycles, concurrency, ordering, cancellation,
  cleanup, retry, and resume;
- interface depth, correct-use difficulty, inputs, outputs, errors, diagnostics,
  resource behavior, and replaceability;
- security, permissions, trust provenance, locality, and execution boundaries;
- persistence, schemas, protocols, compatibility, migration, and data
  integrity;
- performance, backpressure, boundedness, latency, memory, and process costs;
- observability, diagnosability, operability, and recovery behavior;
- test seams and whether tests exercise real public contracts and failure paths;
- configuration, registries, hooks, adapters, dependencies, and extension
  machinery with no demonstrated present need;
- drift between implementation, tests, documentation, and declared invariants;
- redundant, missing, premature, or incorrectly placed abstractions.

Ignore an ordinary local bug unless it demonstrates a systemic ownership,
contract, state, or boundary problem.

## Qualify Findings Strictly

Report a finding only when all of these hold:

- The issue has a meaningful effect on correctness, security, data integrity,
  performance, operability, maintainability, or evolvability.
- It is discrete and actionable at an architectural boundary or ownership
  decision.
- Actual code, callers, state, tests, history, or runtime behavior supports it.
- The affected scenario and consequence are concrete; possible impact alone is
  not enough.
- The recommendation addresses a current requirement or demonstrated cost, not
  a hypothetical future need.
- The proposed design removes or localizes complexity instead of moving it into
  callers, configuration, generated code, or another adapter.

Return every qualifying finding, not a predetermined count. Do not stop at the
first issue and do not add weak findings to make the report look complete.
Merge candidates that share the same architectural cause and target remedy,
while preserving all supporting evidence and affected paths.

Put plausible but insufficiently supported concerns in `Open hypotheses`, with
the evidence needed to settle them. Do not present them as findings.

## Assign Severity and Confidence

- `P0`: A broadly triggered threat to data integrity, security, or fundamental
  system correctness that blocks safe operation or release.
- `P1`: A core state, lifecycle, concurrency, trust, or ownership defect that
  should be redesigned as a priority.
- `P2`: A structural problem with demonstrated maintenance cost, change
  amplification, failure risk, or operational burden.
- `P3`: A lower-impact but evidence-backed architectural simplification. Never
  use P3 for taste, formatting, or speculative extensibility.

Give each finding a confidence score from `0.0` to `1.0`. Severity measures
impact and urgency; confidence measures evidentiary certainty. Do not lower
severity merely because confidence is lower.

## Recommend a Target Design

For every finding, recommend one preferred design and explain why it is the
simplest sufficient correction. State what to delete, merge, deepen, move, or
make explicit; name the resulting owner and public contract. Include breaking
and migration consequences plus checks observable through public interfaces.

For a hard-to-reverse public interface with multiple credible shapes, design
it twice and compare the alternatives by depth, locality, correct-use
difficulty, failure surface, resource behavior, and migration cost. Recommend
one; do not leave an unranked menu.

## Report Findings First

Order findings by severity, then confidence. Use this shape for each finding:

### [P1] Short actionable title

- **Confidence:** `0.00–1.00`
- **Evidence:** Small, direct file/line references plus relevant callers,
  tests, history, or runtime observations. Cross-module evidence is allowed.
- **Impact:** The concrete failure or recurring engineering/operational cost and
  the conditions that trigger it.
- **Architectural cause:** The misplaced responsibility, duplicated knowledge,
  broken contract, or unjustified mechanism.
- **Recommended design:** One preferred target boundary and ownership model.
- **Breaking/migration:** Broken contracts, affected consumers or stored data,
  and required transition work; write `None` when genuinely absent.
- **Acceptance checks:** Observable checks that would prove the new design and
  its failure paths satisfy the requirement.

After the findings, include:

1. `Target architecture synthesis`: the smallest coherent shape implied by the
   findings, boundaries that still earn their keep, and excessive splits that
   were rejected.
2. `Coverage and verification`: inspected areas and flows, commands or tests
   run, and material gaps.
3. `Open hypotheses`: only unresolved concerns and the evidence needed to
   decide them; omit when empty.

Do not emit a numeric architecture score or a binary “correct/incorrect”
verdict. If there are no qualifying findings, say so explicitly, then provide
coverage, verification, and remaining gaps so the empty result is auditable.
