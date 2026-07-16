# Research Review Loop — Security/LLM/ZK Paper

## Overview

Adapts ARIS auto-review-loop for **security + ZK + cryptography + LLM security** research.

Codex reads and improves the paper; a **separate adversarial reviewer** critiques from the perspective of a senior security conference PC member when a native subagent tool is available.

Core principle: *the same model reviewing its own patterns creates blind spots*. The adversarial reviewer simulates a skeptical venue-matched PC member who does not give benefit of the doubt.

Novelty is the first acceptance gate. Before scoring polish or completeness, determine whether the central contribution already exists and whether its delta from the closest prior work is non-obvious. Technical correctness does not compensate for an overlapping, routine, or predictable contribution at a top venue.

## Constants

- `MAX_ROUNDS = 4`
- `POSITIVE_THRESHOLD`: score ≥ 7/10 AND verdict contains "accept" / "ready for submission"
- `REVIEW_DOC`: `AUTO_REVIEW.md` in project root (cumulative log, appended each round)
- `REVIEW_STATE`: `REVIEW_STATE.json` (for context-compaction recovery)
- `HUMAN_CHECKPOINT`: pause after Phase B if `true` (default: `false` — autonomous)
- `TARGET_VENUE`: auto-detect from paper content, or accept argument override
  - Venue/profile hints:
    - proof-heavy crypto signals such as `theorem`, `lemma`, `reduction`, `game`, `simulator`, `ideal functionality`, `assumption` → prefer `CRYPTO/Eurocrypt/PKC/TCC`
    - systems/applied-security signals such as `prototype`, `implementation`, `dataset`, `benchmark`, `latency`, `throughput`, `deployment` → prefer `CCS/USENIX/S&P/NDSS`
    - `zkSNARK/ZKP/verifiable` alone does **not** imply systems emphasis; use surrounding proof-vs-systems signals
    - `TEE/SGX/TDX/CoCo`, `LLM/jailbreak/prompt injection`, `MCP/agent security` → prefer `CCS/USENIX/S&P`
- `REVIEW_PROFILE`: derived from `TARGET_VENUE`
  - `applied-security` for `CCS/USENIX/S&P/NDSS/PETS`
  - `cryptography` for `CRYPTO/Eurocrypt/Asiacrypt/PKC/TCC`

## Reviewer Setup

Priority order:

**Option A - Native subagent available:**

Dispatch a native subagent with the adversarial reviewer prompt. This is the preferred path because it gives the review a separate context.

```
Subagent prompt:
  system: "You are a senior PC member at {TARGET_VENUE} with expertise in {DOMAIN}.
           You are known for finding subtle flaws that authors overlooked.
           Do NOT give benefit of the doubt. If something is unclear, treat it as a weakness."
  task:   "Review the following paper and provide: ..."
```

**Option B - No native subagent available:**

Perform an explicitly skeptical same-model review and state that no separate reviewer was available.

Do not send paper content to remote services or hosted model backends unless the user explicitly asks for that destination.

## Workflow

### Initialization

1. Check `REVIEW_STATE.json`:
   - Does not exist → fresh start
   - `status: "completed"` → fresh start
   - `status: "in_progress"` AND timestamp within 24h → **resume** from saved round
   - `status: "in_progress"` AND timestamp > 24h old → fresh start (stale, delete file)
2. Read all `.tex`, `.org`, `.md` files in the current directory
3. Read `AUTO_REVIEW.md` if exists (prior round context)
4. Detect domain and `TARGET_VENUE`

### Phase A — Self-Assessment (each round)

First choose a rubric from `REVIEW_PROFILE`.

Run the novelty gate in `literature.md` before the venue rubric:

1. Extract each central contribution as problem, setting, mechanism, assumptions, and guarantee.
2. Find and inspect the closest prior work for each contribution.
3. Assign separate prior-art and technical-significance labels.
4. Explain why the delta requires a non-obvious insight, or why it is a routine extension.
5. If evidence is incomplete, use `UNVERIFIED` and make literature verification a critical weakness.

If the only central contribution is `OVERLAP`, `NOVEL BUT OBVIOUS`, or merely `INCREMENTAL`, do not award an accept verdict solely because the work is correct or well presented. For a top venue, normally treat this as a rejection-level weakness unless another substantive contribution independently carries the paper.

**Rubric A — applied-security (`CCS/USENIX/S&P/NDSS/PETS`)**

**Threat model** (15 pts):
- [ ] Adversary capabilities precisely scoped (what the attacker can/cannot do)
- [ ] TCB (Trusted Computing Base) explicitly defined
- [ ] Attack surface enumerated
- [ ] Out-of-scope threats acknowledged

**Security claims** (25 pts):
- [ ] Claims are formally stated (game-based or simulation-based definition), OR clearly scoped as informal
- [ ] For ZK papers: completeness / soundness / zero-knowledge all proved or sketched
- [ ] Security reductions use standard assumptions (DDH, q-SDH, ROM, etc.)
- [ ] No circular reasoning in security arguments

**Novelty vs. top venues** (30 pts):
- [ ] Closest prior work is identified through a contribution-specific search, not only papers already cited by the authors
- [ ] Each claimed delta is checked for both prior-art overlap and non-obvious technical substance
- [ ] The central contribution clears the novelty gate rather than being a routine application, parameter change, or straightforward composition
- [ ] Foundational work and directly related recent or concurrent work are cited
- [ ] No overclaiming ("first" / "only" without qualification)

**Evaluation** (15 pts):
- [ ] Concrete performance numbers (proving time, verification time, overhead vs. plaintext)
- [ ] Comparison vs. alternative approaches or closest baselines
- [ ] If claiming practicality, deployment-relevant or workload-relevant evidence is provided

**Presentation** (15 pts):
- [ ] Threat model section present before the design
- [ ] Security analysis section present after design
- [ ] Proof sketches/theorems before formal proofs when helpful for readability

**Rubric B — cryptography (`CRYPTO/Eurocrypt/Asiacrypt/PKC/TCC`)**

**Model and definitions** (20 pts):
- [ ] Functionality / syntax / security experiment is stated precisely
- [ ] Adversary capabilities and setup assumptions are explicit
- [ ] Security goal matches the claimed contribution

**Theorems and proofs** (35 pts):
- [ ] Main theorem statements are precise and correctly scoped
- [ ] Proof strategy is coherent and free of obvious circularity
- [ ] Assumptions are standard or clearly justified
- [ ] Simulation/reduction loss and model switches are not hand-waved away

**Novelty and relation to prior work** (30 pts):
- [ ] Closest constructions are independently searched and identified
- [ ] Prior-art overlap and non-obviousness are assessed separately for every central contribution
- [ ] Delta is substantive rather than a routine special case, assumption swap, parameter change, or composition
- [ ] Closest prior work is contrasted by functionality, setting, mechanism, assumptions, guarantee, and efficiency
- [ ] No novelty overclaiming

**Efficiency / concreteness** (10 pts):
- [ ] Asymptotic cost is clear
- [ ] Concrete sizes/rounds/field operations/communication are stated when relevant
- [ ] If the paper claims practicality, concrete estimates or experiments support that claim

**Presentation** (5 pts):
- [ ] Main construction intuition is understandable before full proof detail
- [ ] Definitions and theorem order are readable

For `cryptography`, do **not** heavily penalize the absence of systems experiments by itself.
Only treat experiments as important when the paper explicitly claims implementation practicality, deployment readiness, or empirical superiority.

Produce the novelty verdict and comparison evidence first, then the initial score, rubric used, and `WEAKNESSES` list.

### Phase B — Adversarial Review

Use the strongest available review mechanism in this environment:
- native subagent when available
- otherwise perform an explicitly skeptical self-review and state that the loop is same-model
- do not use remote services or hosted model backends unless the user explicitly asks for that destination

Do not assume a specific agent framework, editor integration, API provider, shell, or operating system. Treat all environment-specific options as optional adapters, not requirements.

Reviewer prompt template (fill in paper content):
```
You are a senior PC member at {TARGET_VENUE} with expertise in {DOMAIN}.
You are known for finding subtle flaws that authors overlooked.
Do NOT give benefit of the doubt. If something is unclear, treat it as a weakness.
Judge according to {TARGET_VENUE} norms, not generic security-paper norms.
Treat novelty as the first acceptance gate. For every central contribution, identify the closest prior work, determine whether the claim was already done, and independently judge whether the remaining delta is technically non-obvious. A search miss is not evidence of substantive novelty. A routine application, simple parameter change, obvious special case, or straightforward combination is a rejection-level novelty weakness at a top venue unless it resolves a demonstrated technical obstacle.
If {TARGET_VENUE} is a cryptography venue, prioritize formal model, theorem correctness, assumptions, reductions, and novelty over systems evidence.
Do not heavily penalize missing experiments in a cryptography paper unless the paper itself makes strong practicality or implementation claims.
If {TARGET_VENUE} is an applied-security venue, require stronger empirical support and clearer deployment-relevant evaluation.

Review the following paper and provide:
1. Score: X/10 (1=strong reject, 5=borderline, 7=weak accept, 9=strong accept)
2. Novelty verdict: SUBSTANTIATED NOVELTY / NOVEL BUT OBVIOUS / INCREMENTAL / OVERLAP / UNVERIFIED
3. Contribution-by-contribution closest-prior-work and non-obviousness analysis
4. Top 5 critical weaknesses (ranked by severity)
5. For each weakness: minimum fix needed to address it
6. Verdict: REJECT / BORDERLINE / ACCEPT
7. Missing related work (papers you would expect to see cited)

Paper:
{PAPER_CONTENT}
```

Save the raw response in `AUTO_REVIEW.md` inside a `<details>` block when the environment permits access to that output.

**If HUMAN_CHECKPOINT=true:** Present score + weaknesses to user, wait for instruction (go / skip N / custom instruction / stop).

**Stop condition:** If score ≥ `POSITIVE_THRESHOLD` AND round ≥ 2, terminate loop early.

### Phase C — Targeted Fixes

For each weakness from Phase B, apply the appropriate fix type:

| Weakness Type | Fix Strategy |
|---|---|
| Threat model incomplete | Revise threat model section; add missing adversary capabilities or out-of-scope acknowledgments |
| Missing security proof | Add proof sketch (informal) or full game-based proof; at minimum state the security theorem formally |
| Missing related work | Use literature mode (`references/literature.md`) to find papers; add ≥3 missing citations with one-sentence differentiation |
| Overclaiming novelty | Qualify claims: "to our knowledge" / "in the setting of" / "for the specific case of" |
| Overlapping or obvious contribution | Do not paper over it with wording. Add a genuinely new technical idea or materially stronger result, or honestly reposition the paper and target venue. |
| Weak evaluation | For applied-security: add experiments or stronger baseline comparisons. For cryptography: add concrete complexity tables or tighter efficiency discussion unless the paper explicitly makes empirical claims. |
| Circuit/proof gap (ZK) | Address non-linear op handling; explicitly state lookup tables / range checks used |
| Unclear TCB | Add explicit TCB table: what's trusted, what's not, why |

**Write all changes to the paper files.** Do not simulate fixes — actually edit the document.
Before saving paper edits, apply the main skill's Writing Constraints and preserve citation keys and bibliography markers exactly.

### Phase D — Document Round

Append to `AUTO_REVIEW.md`:
```markdown
## Round N — {TIMESTAMP}

**Score:** X/10  |  **Verdict:** BORDERLINE/ACCEPT/REJECT
**Target venue:** {TARGET_VENUE}
**Novelty verdict:** SUBSTANTIATED NOVELTY / NOVEL BUT OBVIOUS / INCREMENTAL / OVERLAP / UNVERIFIED

### Weaknesses Identified
1. ...

### Fixes Applied
- ...

### Reviewer Raw Response
<details>
<summary>Full reviewer output</summary>
{VERBATIM_REVIEWER_RESPONSE}
</details>
```

Write `REVIEW_STATE.json`:
```json
{
  "round": N,
  "status": "in_progress",
  "last_score": X.X,
  "last_verdict": "...",
  "target_venue": "...",
  "timestamp": "{ISO8601}"
}
```

### Termination

When positive threshold reached OR `MAX_ROUNDS` hit:
1. Update `REVIEW_STATE.json` with `"status": "completed"`
2. Write `REVIEW_SUMMARY.md`:
   - Score progression table
   - Final novelty verdict with closest prior work and unresolved uncertainty
   - Key improvements made per round
   - Remaining open issues (honest list)
   - Suggested venue + rationale
   - Next steps before submission

## Security Venue Standards Reference

| Venue | Tier | Focus | Page limit |
|---|---|---|---|
| CCS, USENIX Security, IEEE S&P, NDSS | 1 | Applied security | 12-18pp |
| CRYPTO, EuroCrypt, AsiaCrypt | 1 | Cryptography/ZK | 30-40pp |
| PKC, TCC | 2 | Cryptography | 30pp |
| PETS | 2 | Privacy | 20pp |

## ZK Paper Checklist (extra, applied in Phase A when domain=zk)

- [ ] Completeness: honest prover always convinces honest verifier
- [ ] Soundness / Knowledge Soundness: no malicious prover can prove false statement (with what probability?)
- [ ] Zero-Knowledge: verifier learns nothing beyond truth of statement
- [ ] Succinctness: proof size and verification time stated (O(1) / O(log n) / O(n)?)
- [ ] Non-linear operations: how are Softmax / LayerNorm / GELU / RELU handled? (lookup tables? sumcheck? approximation?)
- [ ] Setup: trusted / transparent / updateable? What are the assumptions?
- [ ] Prover time complexity stated with concrete numbers for target model size
- [ ] Comparison table: proving time / proof size / verification time vs. prior ZK systems

For proof-centric ZK papers aimed at `CRYPTO/Eurocrypt/PKC/TCC`, treat the last two items as supporting evidence rather than dominant score drivers unless the paper's title/abstract/main claims emphasize practicality.

## Output Files

- `AUTO_REVIEW.md` — cumulative log of all rounds
- `REVIEW_STATE.json` — recovery state
- `REVIEW_SUMMARY.md` — final summary (written at termination)
