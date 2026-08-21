# Evidence And Review Closure

Use this workflow after a paper has measurable claims, provenance artifacts, or an explicit pre-submission review gate. It supplements the master draft and approval gates in `SKILL.md`. It does not authorize new research direction, external publication, or destructive cleanup.

## Recover The Actual State

Read the master draft first. If the workspace predates that contract, reconstruct the immediate state from the current agenda or TODO, latest change log, artifact manifests, publication-file diff, and repository status. Record the reconstruction durably when edits are authorized.

Treat polished LaTeX, a successful build, and a previous review as evidence about state, not as content approval. Identify the one highest-impact unresolved decision before changing prose.

After an interrupted command or session, inspect live processes and partial output before rerunning anything. Preserve partial, failed, and superseded result directories. Never silently merge them into the accepted evidence set or delete them merely to make a launcher resume.

## Close Experiment Provenance

Name the one artifact directory accepted for each reported result. Keep preliminary, interrupted, failed, historical, modeled, and current-executable evidence visibly separate.

Before using a measured claim, verify as applicable:

- exact source, dependency, executable, data, index, command, parameter, query, seed, host, and network-profile identity
- expected run and record counts, success status, failure and retry behavior, realized dimensions, message shapes, and protocol counters
- agreement between raw records, aggregate files, tables, prose, and limitations
- deterministic analysis by regenerating summaries into a temporary path and comparing content or cryptographic hashes with the accepted output

Validation code must fail closed on incomplete or mixed runs. A manifest should identify the accepted artifacts and explain why excluded directories are not paper evidence.

Compile the main paper and supplement after evidence changes. Check undefined citations and references, substantive layout warnings, page boundaries, and whether excluded sections such as ethics or appendices begin where the venue requires. Compilation proves typesetting consistency only.

## Run An Independent Review Gate

For a full venue-readiness pass, use a fresh reviewer context when available. Give it the user request, venue and domain, exact paper paths, required output fields, and permission boundaries. Do not give it prior conclusions, suspected bugs, an expected score, or a desired verdict.

Require findings to include severity, exact evidence, impact, required outcome, acceptance check, and uncertainty. Preserve the raw findings before author-side revision. A reviewer finds and verifies weaknesses. A writer or author decides and edits.

Triage every Critical or High finding into one of four classes:

1. **Existing-evidence closure:** consistency, specification, evidence mapping, honest narrowing, or reproducibility detail can satisfy the acceptance check.
2. **New-evidence closure:** a baseline, ablation, scale point, adversarial test, proof obligation, or artifact is missing.
3. **Research-direction closure:** novelty, deployment value, trust boundary, functionality, or architecture must materially change.
4. **External closure:** an author decision, coauthor input, artifact host, venue action, or other coordination is required.

Do not use wording alone to close classes 2 through 4. Report them as open until their acceptance checks are met or the author explicitly changes scope and records that decision.

## Run Follow-Up Experiments Safely

Before executing a new research experiment, state the exact command and the claim or finding it tests. Verify the input and executable identities, then run the smallest meaningful preflight before the full matrix.

Use a unique output root and make launchers refuse to overwrite partial results. If the intended root already exists, inspect it and choose a new root unless an explicit, validated resume protocol applies. Record failures and environment limitations as provenance rather than paper results.

Define completion from expected records and invariants, not process exit alone. Regenerate the analysis from raw output and inspect whether the result supports, falsifies, or leaves the claim unresolved. Preserve negative results. A result that undermines the proposed mechanism reopens the claim and can block submission even when the experiment itself succeeded.

Stop expanding the experiment when the acceptance check is met, the result falsifies the claim, further work requires a research-direction decision, or the next action needs new authorization.

## Re-Review And Package

After revisions or new evidence, ask the reviewer to check the same Critical and High finding IDs against their acceptance checks. Do not replace this with a generic polish pass.

Create a submission archive only after:

- content and LaTeX gates are authorized
- acceptance-blocking findings are closed or explicitly accepted by the author as residual risk
- claimed artifacts and external URLs are final
- the paper and supplement build from the intended source set

List the archive contents, extract it into a clean temporary directory, and rebuild there. Keep submission sources, reproducibility artifacts, and historical or failed runs separate unless the venue explicitly requires one combined package.

Update the durable paper state with the accepted artifact roots, supported and falsified claims, open blocker IDs, approval scope, and the next decision. Do not let chat history become the only record of why a result or directory was accepted.
