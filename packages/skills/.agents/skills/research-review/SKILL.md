---
name: research-review
description: Use when a security, systems-security, ZK, or cryptography paper draft needs iterative review and improvement. Run an adversarial review loop targeted at venues such as CCS, USENIX Security, IEEE S&P, NDSS, CRYPTO, Eurocrypt, PKC, or TCC, with venue-specific weighting so proof-centric cryptography papers are not over-penalized for lacking systems experiments.
---

# Research Review Loop — Security/LLM/ZK Paper

## Trigger
`/research-review [rounds=4] [human-checkpoint=false]`

## Overview

Adapts ARIS auto-review-loop for **security + ZK + cryptography + LLM security** research.

Claude Code reads and improves the paper; a **separate adversarial reviewer** (dispatched as a native subagent, or via an alternative LLM backend) critiques from the perspective of a senior security conference PC member.

Core principle: *the same model reviewing its own patterns creates blind spots*. The adversarial reviewer simulates a skeptical venue-matched PC member who does not give benefit of the doubt.

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

## Reviewer Setup (Cross-Model)

Priority order — use the first available:

**Option A — Claude Code native (`Agent` tool available):**

Dispatch an `Agent` subagent with adversarial reviewer system prompt. This is the preferred path when running inside Claude Code — truly separate context, no shared blind spots.

```
Agent subagent prompt:
  system: "You are a senior PC member at {TARGET_VENUE} with expertise in {DOMAIN}.
           You are known for finding subtle flaws that authors overlooked.
           Do NOT give benefit of the doubt. If something is unclear, treat it as a weakness."
  task:   "Review the following paper and provide: ..."
  model:  opus  (use the most capable available model)
```

**Option B — magent native (`emacs_eval` tool available, no `Agent` tool):**

Use `emacs_eval` to call `gptel-request` with a non-default backend. This avoids same-model review when running inside magent.

```elisp
;; Write review request to a temp file, then call gptel with Aliyun backend
(let* ((output-file "/tmp/magent-review-output.md")
       (reviewer-prompt "...paper content...")
       (system-prompt "You are a senior PC member at {TARGET_VENUE}..."))
  (gptel-request reviewer-prompt
    :system system-prompt
    :backend (gptel-get-backend "Aliyun")   ; falls back to "Zhipu" if Aliyun unavailable
    :model "qwen-max-latest"
    :callback (lambda (res _info)
                (with-temp-file output-file
                  (insert (or res "ERROR: no response"))))))
```

After calling, read `/tmp/magent-review-output.md` for the reviewer's response. If the Aliyun backend is unavailable, try the "Zhipu" backend with model `"glm-4-plus"`.

**Option C — Dashscope API via curl (universal fallback):**

Use when neither `Agent` nor `emacs_eval` is available, or when gptel backends are not configured.

```bash
# Locate API key
if [ -f ~/.dashscope_api_key ]; then
  DASHSCOPE_KEY=$(cat ~/.dashscope_api_key)
elif [ -n "$DASHSCOPE_API_KEY" ]; then
  DASHSCOPE_KEY=$DASHSCOPE_API_KEY
fi

if [ -z "$DASHSCOPE_KEY" ]; then
  echo "ERROR: No Dashscope key found. Set DASHSCOPE_API_KEY or create ~/.dashscope_api_key"
  exit 1
fi

# Call Qwen-max (OpenAI-compatible endpoint)
curl -s https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions \
  -H "Authorization: Bearer $DASHSCOPE_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen-max-latest",
    "messages": [
      {"role": "system", "content": "You are a senior PC member at {TARGET_VENUE}..."},
      {"role": "user",   "content": "Review this paper: ..."}
    ]
  }'
```

**Decision table:**

| Environment | `Agent` available? | `emacs_eval` available? | → Use |
|---|---|---|---|
| Claude Code | yes | no | **Option A** |
| magent | no | yes | **Option B** |
| Other / API key present | no | no | **Option C** |
| No key, no native tools | no | no | Error — prompt user to configure |

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

**Rubric A — applied-security (`CCS/USENIX/S&P/NDSS/PETS`)**

**Threat model** (20 pts):
- [ ] Adversary capabilities precisely scoped (what the attacker can/cannot do)
- [ ] TCB (Trusted Computing Base) explicitly defined
- [ ] Attack surface enumerated
- [ ] Out-of-scope threats acknowledged

**Security claims** (25 pts):
- [ ] Claims are formally stated (game-based or simulation-based definition), OR clearly scoped as informal
- [ ] For ZK papers: completeness / soundness / zero-knowledge all proved or sketched
- [ ] Security reductions use standard assumptions (DDH, q-SDH, ROM, etc.)
- [ ] No circular reasoning in security arguments

**Novelty vs. top venues** (20 pts):
- [ ] Delta over state-of-art is clearly articulated
- [ ] All directly related work from last 3 years cited
- [ ] No overclaiming ("first" / "only" without qualification)

**Evaluation** (20 pts):
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

**Theorems and proofs** (40 pts):
- [ ] Main theorem statements are precise and correctly scoped
- [ ] Proof strategy is coherent and free of obvious circularity
- [ ] Assumptions are standard or clearly justified
- [ ] Simulation/reduction loss and model switches are not hand-waved away

**Novelty and relation to prior work** (20 pts):
- [ ] Delta over the closest constructions is explicit
- [ ] Closest prior work is cited and contrasted by functionality/assumption/efficiency
- [ ] No novelty overclaiming

**Efficiency / concreteness** (10 pts):
- [ ] Asymptotic cost is clear
- [ ] Concrete sizes/rounds/field operations/communication are stated when relevant
- [ ] If the paper claims practicality, concrete estimates or experiments support that claim

**Presentation** (10 pts):
- [ ] Main construction intuition is understandable before full proof detail
- [ ] Definitions and theorem order are readable

For `cryptography`, do **not** heavily penalize the absence of systems experiments by itself.
Only treat experiments as important when the paper explicitly claims implementation practicality, deployment readiness, or empirical superiority.

Produce initial score, rubric used, and `WEAKNESSES` list.

### Phase B — Adversarial Review

Use the strongest available review mechanism in this environment:
- separate subagent or separate model/backend when available
- otherwise perform an explicitly skeptical self-review and state that the loop is same-model

Do not assume a specific agent framework, editor integration, API provider, shell, or operating system. Treat all environment-specific options as optional adapters, not requirements.

Reviewer prompt template (fill in paper content):
```
You are a senior PC member at {TARGET_VENUE} with expertise in {DOMAIN}.
You are known for finding subtle flaws that authors overlooked.
Do NOT give benefit of the doubt. If something is unclear, treat it as a weakness.
Judge according to {TARGET_VENUE} norms, not generic security-paper norms.
If {TARGET_VENUE} is a cryptography venue, prioritize formal model, theorem correctness, assumptions, reductions, and novelty over systems evidence.
Do not heavily penalize missing experiments in a cryptography paper unless the paper itself makes strong practicality or implementation claims.
If {TARGET_VENUE} is an applied-security venue, require stronger empirical support and clearer deployment-relevant evaluation.

Review the following paper and provide:
1. Score: X/10 (1=strong reject, 5=borderline, 7=weak accept, 9=strong accept)
2. Top 5 critical weaknesses (ranked by severity)
3. For each weakness: minimum fix needed to address it
4. Verdict: REJECT / BORDERLINE / ACCEPT
5. Missing related work (papers you would expect to see cited)

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
| Missing related work | Use `research-lit` skill to find papers; add ≥3 missing citations with one-sentence differentiation |
| Overclaiming novelty | Qualify claims: "to our knowledge" / "in the setting of" / "for the specific case of" |
| Weak evaluation | For applied-security: add experiments or stronger baseline comparisons. For cryptography: add concrete complexity tables or tighter efficiency discussion unless the paper explicitly makes empirical claims. |
| Circuit/proof gap (ZK) | Address non-linear op handling; explicitly state lookup tables / range checks used |
| Unclear TCB | Add explicit TCB table: what's trusted, what's not, why |

**Write all changes to the paper files.** Do not simulate fixes — actually edit the document.

### Phase D — Document Round

Append to `AUTO_REVIEW.md`:
```markdown
## Round N — {TIMESTAMP}

**Score:** X/10  |  **Verdict:** BORDERLINE/ACCEPT/REJECT
**Target venue:** {TARGET_VENUE}

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
