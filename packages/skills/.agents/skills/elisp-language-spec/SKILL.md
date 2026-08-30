---
name: elisp-language-spec
description: Apply Jamie's Emacs Lisp implementation rules for precise error handling, safe accessor use, rollback visibility, actionable checkdoc hygiene, and layered validation. Use when writing or revising .el code; do not use for generic live Emacs interaction or a read-only package review.
---

# Emacs Lisp Language Specification

Write Elisp whose failure behavior is explicit and inspectable.  Repository
instructions, public API contracts, and the declared minimum Emacs version take
precedence over this skill.

## Error Handling

Do not use `ignore-errors` as a routine way to turn failures into `nil`.  First
classify why failure is expected, then encode that boundary directly:

- Guard struct accessors with the corresponding predicate.  For an optional
  external object, check both API availability and object type before calling
  its accessor.
- Call query APIs directly when their documented absence result is already
  `nil`.  Let contract violations and configuration errors remain visible.
- Use `condition-case` only for expected conditions and catch the narrowest
  useful condition, such as `file-error`, `json-error`, or
  `json-parse-error`.  Do not catch `error` merely because a probe is optional.
- At a true isolation boundary, such as a diagnostic probe runner, catching
  `error` is acceptable when the boundary records or returns the failure rather
  than silently discarding it.

Prefer this shape for optional accessors:

```elisp
(and (fboundp 'widget-p)
     (widget-p value)
     (fboundp 'widget-name)
     (widget-name value))
```

For parsers that intentionally scan multiple candidates, suppress only parse
failures so unexpected API or type errors still surface:

```elisp
(condition-case nil
    (json-parse-string text)
  ((json-error json-parse-error) nil))
```

### Rollback and cleanup

Preserve the primary failure.  If rollback cleanup or a registry reload can
also fail, catch that secondary failure, report it through the package's
logging path, restore all state that can still be restored, and then re-signal
the original condition.  Never let a silent cleanup failure make partially
restored state look healthy.

```elisp
(condition-case primary-error
    (perform-change)
  (error
   (condition-case cleanup-error
       (rollback-change)
     (error
      (message "Rollback failed: %s"
               (error-message-string cleanup-error))))
   (signal (car primary-error) (cdr primary-error))))
```

### Security-sensitive transformations

Fail closed.  Redaction, path normalization, permission canonicalization, and
serialization must reject invalid input instead of skipping it and continuing
with unredacted or ambiguous data.  Define and signal a package-specific error
when callers need to distinguish a rejected value from ordinary absence.

## API and Type Boundaries

- Validate values before generated struct accessors; accessor errors are not a
  substitute for type checks.
- Keep optional integrations lazy with `fboundp` or `boundp`, but do not use
  those checks to conceal malformed values after an integration is present.
- Make `declare-function` name the real defining library and signature.  Use an
  `ext:` declaration only for generated or otherwise nonstandard definitions.
- Remove declarations made redundant by a compile-time `require`; preserve
  justified declarations for genuinely lazy features.
- Treat private APIs containing `--` as compatibility risks and isolate them in
  the narrowest module that owns the integration.

## Messages and Documentation

Run `checkdoc` as a reviewer, not as a mechanical rewrite tool.  Fix diagnostics
that improve user-facing behavior or documentation, including:

- Start `error`, `user-error`, and prompt messages with a capital letter.
  Preserve a machine-readable lowercase code by prefixing it, for example
  `"Error stale_revision: ..."` or `"Invalid input: field_name ..."`.
- End `y-or-n-p` and `yes-or-no-p` prompts with `?`.
- Quote Lisp symbols and functions with backtick/apostrophe notation.
- Escape a literal opening parenthesis at the start of a docstring line with
  `\\=(` when checkdoc would otherwise parse it as prose structure.
- Do not describe the symbols `t` and `nil` with ordinary single quotes.  Use
  symbol quoting when they are the actual symbols; choose a different example
  letter when they are not.
- Give shipped Elisp libraries a useful `;;; Commentary:` section.  If a
  generated file is shipped, align its generator or maintained header rather
  than relying on a transient manual edit.
- Capitalize variable docstring openings even when the first token is a
  lowercase package or tool name.  A form such as
  `"Tool definition for `read_file'."` stays both accurate and checkdoc-clean.

Argument-name warnings require judgment.  Public functions should document
their arguments clearly and use the exact uppercase argument names.  Do not
rewrite large numbers of obvious internal callback docstrings solely to drive
the warning count to zero; confirm that no actionable diagnostics are hidden
among that noise.

## Tests

Test the behavior created by the error boundary, not the presence or absence of
one spelling.  Useful regression checks include:

- invalid security inputs fail with the intended typed condition;
- malformed optional objects fall back without invoking an accessor;
- expected parse failures allow the next candidate to be tried;
- rollback reports its secondary failure while preserving the primary error;
- error-message cleanup retains any stable machine-readable code consumed by
  callers or tests.

Avoid a blanket test that bans `ignore-errors` forever.  A future use may be
justified; it must instead be narrow, documented, and reviewed in context.

## Validation

Use the repository's own commands first.  For a package-wide change:

1. Inventory production `ignore-errors` sites and inspect every caller before
   editing.
2. Run checkdoc across all shipped Elisp files and separate argument-name noise
   from other diagnostics.
3. Remove stale `.elc` files through the repository's supported clean target
   when compilation reports that source is newer than loaded bytecode.
4. Byte-compile from a clean state, then run declaration checks, package lint,
   focused ERT tests, and the full unit suite when the touched boundary is
   shared.
5. Distinguish a sandbox or unwritable session-directory failure from a code
   regression; rerun only with the authority needed by the test environment.

Before handoff, re-run the production searches, inspect the complete diff, and
state any intentionally retained checkdoc category or broad error boundary.
