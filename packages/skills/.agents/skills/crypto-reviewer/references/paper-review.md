# Full Paper Review - Security, LLM, ZK, And Cryptography

## Scope

Use this workflow for a complete venue-readiness or peer review. Review one draft version at a time. Do not edit the paper, run an automatic revise-and-review loop, or create state files.

Novelty is the first acceptance gate. Technical correctness and presentation do not compensate for a central contribution that overlaps prior work or is a routine, predictable extension.

## Select The Review Profile

Use the target venue stated by the user or paper. Otherwise infer it from the draft:

- Proof-heavy signals such as `theorem`, `lemma`, `reduction`, `game`, `simulator`, `ideal functionality`, and `assumption` favor `CRYPTO`, `EUROCRYPT`, `ASIACRYPT`, `PKC`, or `TCC`.
- Systems and applied-security signals such as `prototype`, `implementation`, `dataset`, `benchmark`, `latency`, `throughput`, and `deployment` favor `CCS`, `USENIX Security`, `IEEE S&P`, `NDSS`, or `PETS`.
- `zkSNARK`, `ZKP`, or `verifiable` alone does not select a systems profile. Use the surrounding proof and evaluation signals.
- TEE, SGX, TDX, confidential computing, LLM security, prompt injection, MCP, and agent security usually favor the applied-security profile unless formal results dominate the paper.

Use:

- `applied-security` for `CCS`, `USENIX Security`, `IEEE S&P`, `NDSS`, and `PETS`
- `cryptography` for `CRYPTO`, `EUROCRYPT`, `ASIACRYPT`, `PKC`, and `TCC`

State the inferred venue, evidence, and confidence. Ask for the target venue only when plausible profiles would materially change the verdict.

## Use An Independent Review Context

For a full review, dispatch a native subagent with a fresh context when available. Give it:

- the user request
- target venue and domain
- the paper or exact local paths it must inspect
- the required output fields

Do not give it prior conclusions, suspected bugs, an expected score, or an intended verdict. The independent pass must be capable of disagreeing.

Do not use a third-party model or remote review backend unless the user explicitly names and authorizes that destination. If no native subagent is available, perform an explicitly skeptical same-context review and disclose that limitation.

## Full Review Workflow

### 1. Establish The Paper's Claims

Extract:

- central contributions
- formal and informal security claims
- setup and adversary assumptions
- proof obligations
- implementation and evaluation claims
- stated limitations and out-of-scope threats

Rewrite each central contribution as a falsifiable claim with problem, setting, mechanism, assumptions, guarantee, and cost.

### 2. Run The Novelty Gate

For every central contribution:

1. Search independently for the closest prior work.
2. Compare the complete technical tuple, not titles or keywords alone.
3. Assess prior-art status as `NOT_FOUND`, `PARTIAL`, `OVERLAP`, or `UNVERIFIED`.
4. Assess technical significance as `SUBSTANTIVE`, `OBVIOUS`, `INCREMENTAL`, or `UNVERIFIED`.
5. Explain the conceptual obstacle resolved by the delta, or why the change is routine.
6. State search coverage and unresolved uncertainty.

Use one overall verdict:

- `SUBSTANTIATED NOVELTY`
- `NOVEL BUT OBVIOUS`
- `INCREMENTAL`
- `OVERLAP`
- `UNVERIFIED`

If the only central contribution is overlapping, obvious, or merely incremental, treat that as a rejection-level weakness for a top venue unless another independent substantive contribution carries the paper.

### 3. Apply The Venue Rubric

#### Applied-Security Profile

**Threat model: 15 points**

- adversary capabilities are precise
- trusted computing base is explicit
- attack surface is enumerated
- out-of-scope threats are acknowledged

**Security claims: 25 points**

- claims are formally stated or clearly scoped as informal
- ZK completeness, soundness, and zero knowledge are proved or adequately sketched
- reductions use stated and justified assumptions
- security arguments avoid circular reasoning

**Novelty and prior work: 30 points**

- closest work is independently searched, not taken only from the bibliography
- overlap and non-obviousness are assessed separately
- central contributions clear the novelty gate
- foundational, recent, and concurrent work is covered
- priority claims are qualified and supported

**Evaluation: 15 points**

- performance numbers support the main claims
- baselines include the closest credible alternatives
- practicality claims use deployment-relevant workloads or evidence

**Presentation: 15 points**

- the threat model appears before designs that depend on it
- the security analysis follows the design coherently
- proof sketches or intuition precede dense formal detail when useful

#### Cryptography Profile

**Model and definitions: 20 points**

- syntax, functionality, or security experiments are precise
- adversary capabilities and setup assumptions are explicit
- the security goal matches the claimed contribution

**Theorems and proofs: 35 points**

- theorem statements are precise and correctly scoped
- proof strategy is coherent and avoids circularity
- assumptions are standard or justified
- reduction loss, hybrids, and model changes are not hidden

**Novelty and prior work: 30 points**

- closest constructions are independently searched
- overlap and non-obviousness are assessed separately
- the delta is more than a routine special case, assumption swap, parameter change, or composition
- comparisons cover functionality, setting, mechanism, assumptions, guarantee, and efficiency
- novelty claims do not overreach the evidence

**Efficiency and concreteness: 10 points**

- asymptotic cost is clear
- concrete sizes, rounds, field operations, or communication are stated when relevant
- practicality claims have concrete estimates or experiments

**Presentation: 5 points**

- construction intuition precedes full proof detail
- definitions and theorems appear in a usable order

Do not heavily penalize a cryptography paper for lacking systems experiments unless it claims implementation practicality, deployment readiness, or empirical superiority.

### 4. Run The Adversarial Pass

Use this task framing for the independent reviewer:

```text
Act as a skeptical senior PC member at {TARGET_VENUE} with expertise in {DOMAIN}.
Judge according to the selected venue, not generic paper-writing norms.
Do not give unclear claims the benefit of the doubt.

Treat novelty as the first acceptance gate. For every central contribution,
identify the closest prior work, assess prior-art overlap separately from
technical significance, and explain whether the delta resolves a genuine
technical obstacle. A search miss is not evidence of substantive novelty.

Then audit the threat model, definitions, proofs, security arguments,
evaluation, limitations, and presentation using the selected rubric.

Return:
1. novelty verdict and search uncertainty
2. contribution-by-contribution closest-prior-work comparison
3. score from 1 to 10 and ACCEPT, BORDERLINE, or REJECT
4. severity-ordered findings with evidence
5. required outcome and acceptance check for every finding
6. missing related work

Do not edit the paper, draft replacement prose, or generate a patch.
```

Reconcile the independent pass with direct evidence. Do not hide disagreements. When the reviewers differ, report both positions and state what additional evidence would resolve the dispute.

### 5. Produce The Review

Lead with novelty, then score and findings. Use the finding schema from `crypto-reviewer/SKILL.md`.

Severity meanings:

- `Critical`: invalidates a central claim, breaks the security argument, or blocks submission.
- `High`: materially threatens correctness, novelty, or acceptance.
- `Medium`: requires substantive clarification or evidence but does not independently invalidate the paper.
- `Low`: localized presentation, completeness, or reproducibility issue.

Required outcomes must describe what must become true. Acceptance checks must be observable in a revised draft. Do not provide publication-ready replacement text.

## Finding-Type Guidance

| Finding type | Required outcome |
|---|---|
| Threat model incomplete | State missing capabilities, trust assumptions, attack surfaces, and exclusions consistently |
| Security claim unsupported | Add a correctly scoped definition and proof, or narrow the claim to the available evidence |
| Related work missing | Cite and technically distinguish the closest prior work |
| Novelty overclaimed | Support the priority claim or narrow it to the verified setting |
| Contribution overlapping or obvious | Add a substantive technical result or reposition the work honestly |
| Applied-security evaluation weak | Add credible baselines and deployment-relevant measurements |
| Cryptography efficiency unclear | State asymptotic and concrete costs appropriate to the claim |
| ZK circuit or proof gap | Account for nonlinear operations, lookup or range constraints, setup, and soundness |
| Trusted computing base unclear | Enumerate trusted components, excluded components, and justification |

## ZK Checklist

- completeness is defined and supported
- soundness or knowledge soundness specifies the adversary and error probability
- zero knowledge specifies what the verifier learns
- proof size and verifier complexity are stated
- nonlinear operations and range constraints are accounted for
- setup is classified as trusted, transparent, or updateable
- assumptions are explicit
- prover complexity is concrete enough for the paper's claims
- comparisons include proving time, proof size, and verification time when relevant

For proof-centric ZK papers, treat implementation metrics as supporting evidence rather than dominant score drivers unless practicality is a central claim.

## Version Review

When the user supplies an earlier review:

- preserve finding IDs for unchanged issues
- label prior findings `RESOLVED`, `PARTIAL`, `OPEN`, or `REGRESSED`
- verify resolutions against acceptance checks
- assign new IDs to newly discovered issues
- compare scores only under the same venue and rubric
- explain score changes through resolved or new findings

Do not create review history or state files unless the user explicitly requests a saved report.
