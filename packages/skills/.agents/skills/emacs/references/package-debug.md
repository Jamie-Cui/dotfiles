# Package Debug Workflow

Use this workflow for Emacs package development problems across agents and operating systems.

## Standard Sequence

1. Reproduce the failure in the running Emacs session.
2. Enable `debug-on-error` and, when useful, `debug-on-quit`.
3. Refresh the file under development through the package's normal load or test path. Confirm first if the refresh mutates the user's live session.
4. Inspect `*Messages*`, `*Warnings*`, and `*Backtrace*`.
5. Byte-compile the changed file to surface warnings, missing requires, obsolete APIs, or macro expansion issues.
6. Run focused ERT tests if present.
7. Inspect feature state and symbol state without dumping raw variable values:
   - `featurep`
   - `fboundp`
   - `boundp`
   - value type for critical variables
8. Inspect buffer-local state, hooks, keymaps, or minor mode activation if the bug is contextual.

## Common Failure Patterns

- `void-function`: missing `require`, stale load order, or typo in generated/autoloaded symbol.
- `void-variable`: lexical binding mismatch, file not reloaded, or variable defined only in another feature.
- Hook runs but behavior is wrong: inspect hook membership and buffer-local values.
- Command exists but key does not work: inspect active maps, minor modes, and overriding maps.
- Tests pass in isolation but fail interactively: inspect persistent global state and buffer-local state left over from earlier runs.
- Byte compilation warns about free variables or unknown functions: usually indicates missing declarations or requires.

## Minimal Triage Data To Capture

- Exact error message
- Relevant `*Backtrace*` frames
- Relevant `*Messages*` lines
- File(s) reloaded
- Test command and failing test names
- Whether the issue reproduces after reloading only the changed package files
