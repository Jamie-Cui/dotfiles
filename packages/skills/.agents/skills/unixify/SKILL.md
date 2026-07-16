---
name: unixify
description: Apply Unix philosophy and pragmatic Linux engineering to simplify software, place knowledge in data, define focused responsibilities and composable interfaces, make behavior inspectable, and evolve designs without speculative machinery. Use when the user asks to unixify or apply Unix philosophy, or asks about Unix-style composition, pipelines and filters, CLI automation, responsibility boundaries, policy-mechanism separation, replaceable interfaces, machine-oriented I/O, or observable failure behavior. Do not trigger for ordinary Unix or Linux usage or generic software design without one of these signals.
---

# Unixify

Shape software around simple responsibilities, explicit representations, and composable interfaces. Apply classic Unix principles as strong heuristics, then honor modern constraints around correctness, security, compatibility, performance, transactions, and operations. Support reviews and, when requested, implementation and verification.

## Work in Order

1. **Frame the outcome.** State the required result, non-negotiable constraints, published behavior, and observed source of complexity. Distinguish current requirements from guesses about future needs.
2. **Remove accidental complexity.** Delete or defer unjustified features, layers, state, configuration, dependencies, indirection, and special cases. Prefer clear, direct designs over clever ones; code size alone neither proves nor disproves good modularity.
3. **Put knowledge in data.** Look for mappings, rules, schemas, tables, or state transitions hidden in procedural branches. Move them into explicit data when that makes behavior easier to inspect and validate, but do not merely trade code complexity for an unbounded configuration language. Automate repetitive, error-prone work or generate artifacts only when the source description is simpler than the output and generated results need no hand-editing.
4. **Establish justified boundaries.** Separate responsibilities when they vary, are reused, are replaced, are tested, are secured, or fail independently. Separate policy from mechanism when callers control them differently or they change on different timescales. Define logical modules first; choose another process or service only when lifecycle, privilege, fault isolation, scaling, runtime, or ownership requires it.
5. **Design composable interfaces.** Specify inputs, primary results, diagnostics, errors, status, ordering, and resource behavior. Make either side replaceable without knowledge of the other's internals. Choose the simplest sufficient representation:
   - Use typed in-process APIs for composition inside one program.
   - Use line-oriented text for simple record streams that benefit from standard tools.
   - Use versioned structured formats for stable fields, nesting, validation, or schema evolution.
   - Use binary formats when precision, throughput, size, latency, or an established standard justifies them.
   Support incremental processing when it reduces latency or bounds resource use. Keep data-producing commands stable and pipe-friendly; let interactive tools expose an explicit noninteractive machine mode.
6. **Make behavior transparent and robust.** Make valid input, state transitions, and output relationships easy to inspect and test. Add `--dry-run`, `--explain`, structured diagnostics, metrics, or tracing only where they materially improve diagnosis. Exercise empty, large, unusual, and machine-generated inputs without proliferating special cases. For CLIs, write primary data to standard output, diagnostics to standard error, stay quiet on ordinary success, make verbosity opt-in, and return meaningful exit status.
7. **Repair deliberately.** Accept harmless variation only when the contract defines it. Recover only when the repair is unambiguous and cannot conceal corruption; otherwise fail early, visibly, and close to the cause. Never silently reinterpret malformed or security-relevant input. Emit strict, documented output for the next component.
8. **Evolve without speculation.** Preserve published CLI, API, protocol, and file-format behavior by default. Use compatible extensions, explicit versions, self-describing clauses, or deprecation paths where evolution is real. Leave stable joints that can accept future change, but do not build hypothetical plugins, hooks, services, or options.
9. **Prototype, measure, and verify.** Get the smallest clear design working before polishing it. Measure before optimizing and add local complexity only where evidence identifies a worthwhile bottleneck. Verify preserved behavior, new composition points, failure paths, and resource bounds; for a conceptual review, state checks without claiming they ran.

## Work with KISS

Run independently; do not require the KISS skill. When both apply, use KISS first to remove unnecessary concepts and mechanisms, then use Unixify to shape the responsibilities, representations, and composition interfaces that remain. Do not duplicate the full KISS workflow here.

## Check the Design

- Is each responsibility focused, and is every boundary justified?
- Are interfaces explicit, inspectable, composable, and replaceable?
- Is the implementation clear rather than clever?
- Could stable knowledge move from branching logic into validated data?
- Is routine success quiet while useful diagnostics remain available?
- Does invalid input fail promptly without silent damage or guesswork?
- Can tests and operators observe the state needed to diagnose behavior?
- Should repetitive detail be automated or generated from a simpler source?
- Is every optimization supported by measurement?
- Can published interfaces evolve without speculative machinery?

## Guardrails

- Do not equate composability with microservices, separate processes, plugins, shell pipelines, or text-only protocols.
- Do not hide complexity behind adapters, configuration, generated code, or abstraction; remove it or give it an explicit owner.
- Do not make permissive parsing, noisy output, or pervasive instrumentation substitutes for a clear contract.
- Do not sacrifice correctness, security, data integrity, type safety, transactions, performance, accessibility, observability, compatibility, or established platform conventions for architectural purity.
- Treat Unix and Linux maxims as design heuristics, not mandatory historical implementation forms.

## Communicate the Result

Lead with the recommended design or completed change. Briefly identify the required constraints, complexity removed or deferred, responsibility boundaries, representations and composition interfaces, rejected excessive splits, compatibility impact, failure behavior, measurements, and verification performed.
