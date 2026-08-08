# LaTeX Handoff

Read this reference only after the master draft records explicit content approval and authorization to change LaTeX.

## Verify The Gate

Require all of the following:

- `content_approved` is `yes`
- `approved_at` records a date
- `approved_scope` identifies the accepted content or revision
- `latex_gate` is `authorized`
- `paper_phase` is `latex-translation`

Run `scripts/paper_state.py audit` and `scripts/paper_state.py handoff`. Stop if either command reports a gate or consistency error.

## Establish The Mapping

Map every intended paper section to approved draft sections before editing LaTeX. Record:

- source heading
- destination `.tex` file or section
- relevant claim IDs
- citation keys and mathematical objects
- completion status

Exclude workflow metadata, discussion agendas, rejected claims, and change logs from publication prose.

## Translate The Approved Content

1. Preserve the approved problem, assumptions, guarantees, and limitations.
2. Preserve citation keys, notation, theorem meaning, and evidence status.
3. Reorganize and polish only within the approved scope.
4. Add no new novelty, security, correctness, performance, or practicality claim.
5. Keep generated figures and tables traceable to approved evidence.

Treat the master draft as authoritative when wording differs.

## Reopen Substantive Problems

Stop translation when it exposes a missing assumption, contradictory claim, invalid proof target, unsupported result, or evaluation gap.

Return to the master draft, mark the affected decision or claim open, record the reason, and freeze further research-driven LaTeX edits. Resume translation only after renewed approval and authorization.

Do not reopen the content gate for typography, mechanical citation placement, line breaking, or template-only changes.

## Validate The Publication Artifact

- compare every central LaTeX claim against its approved draft source
- check citations, equations, figures, tables, and terminology
- compile and inspect the rendered paper
- confirm that limitations and non-goals remain visible
- report unmapped draft sections and LaTeX text without an approved source
