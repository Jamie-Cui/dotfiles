---
name: unixify
description: Apply Unix philosophy and pragmatic Linux engineering to simplify software, place knowledge in data, shape deep tools with focused responsibilities and composable interfaces, make behavior inspectable, and evolve designs without speculative machinery. Use when the user asks to unixify or apply Unix philosophy, or asks about Unix-style composition, module or responsibility boundaries, pipelines and filters, CLI automation, policy-mechanism separation, replaceable interfaces, machine-oriented I/O, observable failure behavior, or evolvable interfaces. Do not trigger for ordinary Unix or Linux usage or generic software design without one of these signals.
---

# Unixify

Shape software around simple responsibilities, deep tools with small surfaces, explicit representations, and composable contracts. Apply classic Unix principles as strong heuristics, then honor modern constraints around correctness, security, compatibility, performance, transactions, accessibility, and operations. Support reviews and, when requested, implementation and verification.

## Work in Order

1. **Scope the change.** Start with the module, command, data flow, or pain point the user named. Inspect the implementation, callers, tests, and published documentation that define its current behavior; do not treat a proposal as evidence of what the system does. For a broad review, inspect recent history to find frequently changed areas before widening the scan. Read relevant `CONTEXT.md` files and ADRs when present. State the required result, non-negotiable constraints, published behavior, and observed source of complexity; separate current needs from future guesses.

   Complete this stage when the review target, hard constraints, compatibility surface, and factual current behavior are explicit.

2. **Shape a deep tool.** Delete or defer unjustified features, layers, state, configuration, dependencies, indirection, special cases, and other mechanisms. Prefer clear, direct designs over clever ones; code size alone neither proves nor disproves good modularity.

   Put knowledge in data: look for mappings, rules, schemas, tables, or state transitions hidden in procedural branches. Move them into explicit data when that makes behavior easier to inspect and validate, but do not merely trade code complexity for an unbounded configuration language. Automate repetitive, error-prone work, or generate artifacts only when the source description is simpler than the output and generated results need no hand-editing.

   Keep the outward surface small while allowing the implementation to own the complexity it hides. Separate responsibilities when they vary, are reused, are replaced, are tested, are secured, or fail independently. Separate policy from mechanism when callers control them differently or they change on different timescales. Establish a boundary only for a concrete present need.

   Read [references/module-design.md](references/module-design.md) when reviewing or changing modules, APIs, adapters, service boundaries, or test seams. Complete this stage when every retained boundary and mechanism has a concrete present-day justification and removed complexity has not merely moved into callers or configuration.

3. **Define the composition contract.** Specify inputs, primary results, diagnostics, errors, status, ordering, cancellation, and resource behavior. Make either side usable and replaceable through the contract without knowledge of the other's internals. Choose the simplest sufficient representation. Define logical modules first; choose another process or service only when lifecycle, privilege, fault isolation, scaling, runtime, or ownership requires it.

   Make valid input, state transitions, and output relationships easy to inspect and test. Add `--dry-run`, `--explain`, structured diagnostics, metrics, or tracing only where they materially improve diagnosis. Exercise empty, large, unusual, and machine-generated inputs without proliferating special cases.

   Repair deliberately. Accept harmless variation only when the contract defines it. Recover only when the repair is unambiguous and cannot conceal corruption; otherwise fail early, visibly, and close to the cause. Never silently reinterpret malformed or security-relevant input. Emit strict, documented output for the next component.

   Evolve without speculation. Preserve published CLI, API, protocol, and file-format behavior by default. Use compatible extensions, explicit versions, self-describing clauses, or deprecation paths where evolution is real. Leave stable joints that can accept future change without building hypothetical plugins, hooks, services, modes, or options.

   Read [references/cli-and-data-contracts.md](references/cli-and-data-contracts.md) for CLIs, pipelines, parsers, protocols, machine modes, or public data formats. Complete this stage when callers can use and test each public interface from its documented behavior alone, including failure paths.

4. **Prototype, measure, verify, and report.** Get the smallest clear design working before polishing it. If evidence cannot settle a design question, build the smallest disposable prototype that answers that one question; keep the answer and discard the prototype. Measure before optimizing and add local complexity only where evidence identifies a worthwhile bottleneck. Verify preserved behavior, new composition points, failure paths, and relevant resource bounds through public interfaces. For a conceptual review, state the checks that remain without claiming they ran.

   Complete the work when every material claim is backed by an executed check, an inspected artifact, or an explicit unverified assumption.

## Work with KISS

Run independently; do not require the KISS skill. When both apply, use KISS first to remove unnecessary concepts and mechanisms, then use Unixify to shape the responsibilities, representations, and composition contracts that remain. Do not duplicate the full KISS workflow here.

## Check the Design

- Is each responsibility focused, and is every boundary justified?
- Are interfaces explicit, inspectable, composable, and replaceable?
- Is each outward surface small enough for the useful behavior it provides?
- Does the deletion test show that each retained module concentrates rather than merely moves complexity?
- Is the implementation clear rather than clever?
- Could stable knowledge move from branching logic into validated data?
- Is routine success quiet while useful diagnostics remain available?
- Does invalid input fail promptly without silent damage or guesswork?
- Can tests and operators observe the state needed to diagnose behavior?
- Should repetitive detail be automated or generated from a simpler source?
- Is every optimization supported by measurement?
- Can published interfaces evolve without speculative machinery?
- Is every recommendation identified as a hard requirement, a Unix-informed heuristic, or an unverified assumption?

## Guardrails

- Do not equate composability with microservices, separate processes, plugins, shell pipelines, or text-only protocols. Keep composability representation-neutral: typed APIs, text streams, structured data, binary protocols, modules, and processes are all valid when their constraints justify them.
- Do not hide complexity behind adapters, configuration, generated code, or abstraction; remove it or give it an explicit owner.
- Do not make permissive parsing, noisy output, or pervasive instrumentation substitutes for a clear contract.
- Do not sacrifice correctness, security, data integrity, type safety, transactions, performance, accessibility, observability, compatibility, or established platform conventions for architectural purity.
- Treat Unix and Linux maxims as design heuristics, not mandatory historical implementation forms.
- Preserve published CLI, API, protocol, and file-format behavior by default, and prefer stable joints that accept real change over speculative machinery.

## Communicate the Result

Lead with the recommended design or completed change. Separate required constraints from Unix-informed heuristics. Briefly identify complexity removed or deferred, responsibility boundaries and why they earn their keep, representations and composition interfaces, rejected excessive splits, compatibility impact, failure behavior, measurements, and verification performed.
