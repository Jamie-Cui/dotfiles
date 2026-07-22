# CLI and Data Contracts

Read this reference for CLIs, pipelines, parsers, protocols, machine modes, or public data formats.

## Choose the representation

- Use typed in-process APIs when composition stays inside one program.
- Use line-oriented text for simple record streams that benefit from standard tools.
- Use versioned structured formats for stable named fields, nesting, validation, or schema evolution.
- Use binary formats when precision, throughput, size, latency, or an established standard justifies them.
- Prefer incremental processing when it lowers latency or bounds memory. Document ordering, buffering, cancellation, and partial-result behavior when callers depend on them.

## Define command behavior

- Write primary data to standard output and diagnostics to standard error.
- Stay quiet on ordinary success; make human-oriented detail and verbosity explicit.
- Return meaningful, documented exit status. Keep machine-readable output valid on failure according to its contract instead of mixing prose into it.
- Give interactive commands an explicit noninteractive mode when automation is a supported use case. Define TTY-sensitive behavior rather than guessing silently.
- Accept input from files, arguments, or standard input according to one clear precedence rule. Make empty input, broken pipes, interruption, and partial writes observable.

## Parse and repair deliberately

- Accept harmless variation only when the contract defines it.
- Repair input only when the correction is unambiguous and cannot conceal corruption. Otherwise fail visibly and close to the cause.
- Treat malformed, ambiguous, security-relevant, and integrity-sensitive input strictly.
- Emit one strict documented form for the next component even when the parser accepts broader input.

## Evolve published contracts

- Preserve published flags, exit codes, protocols, and file formats by default.
- Prefer compatible field additions or self-describing clauses where readers can safely ignore what they do not understand.
- Introduce explicit versions when interpretation changes, not merely because change is conceivable.
- Use a deprecation path when callers need time to migrate; state the replacement and removal condition.

## Keep behavior inspectable

Add `--dry-run`, `--explain`, structured diagnostics, metrics, or tracing only where each resolves a concrete diagnostic gap. Exercise empty, large, unusual, and machine-generated inputs without creating separate behavior for every case.
