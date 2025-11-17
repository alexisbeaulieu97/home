---
name: root-cause-tracing
description: Use when investigating an issue whose origin is unclear, especially when symptoms appear far from the cause. Trigger cues - "bug", "unexpected behavior", "traceback", "why is this happening", "non-deterministic failure". Goal - Trace causality backward to find and validate the true root cause before fixing.
---

# Root Cause Tracing (Causal Debugging Mode)

## Goal
Find the origin of the failure, not just where it surfaces. Temporary patches are acceptable for urgent recovery but must include monitoring and follow-up RCA.

## Persona
Calm, evidence-first investigator. Flags uncertainty and evidence gaps explicitly.

## Process

### Phase 1 — Observe the Symptom
- Restate the failure precisely.
- Capture immediate evidence (logs/traces/telemetry, failing conditions, timelines).
- If urgent: apply temporary patch **with monitoring** and create a follow-up RCA task.

### Phase 2 — Gather Context
- Add/inspect instrumentation at the failure site.
- Capture: key variables/inputs, environment/config state, call/data path, recent changes.
- For intermittents: collect multiple samples to identify patterns; avoid hypotheses.

### Phase 3 — Trace Backward with Bounded Systemic Scan
**3A. Primary Chain (default):**
- Follow the **strongest-evidence chain** (directly logged/observable/reproducible transitions) upstream one link at a time.
- Ask **why** each upstream condition occurred; stop at earliest invalid state/assumption.

**3B. Concurrent Mapping (only if systemic signals present):**
- Signals: cross-service impact, env/code interaction, correlated alerts across components.
- Build a **3–5 factor map** (evidence-ranked). For top 1–2 factors, add **sentinel checks/instrumentation** in parallel.
- If the primary chain stalls, pivot to the highest-evidence mapped branch.

- Always record missing evidence (“Need upstream audit logs”, “Hardware sensor data absent”).

### Phase 4 — Validate
- Form 1–2 concise root-cause hypotheses.
- Reproduce; if non-reproducible, use statistical patterns, fuzzing, controlled input variation.
- Confirm: a fix at this origin removes the failure with no unintended effects.
- Record confidence (e.g., “80%—awaiting config snapshot from host B”).

### Phase 5 — Fix + Defenses
- Apply a **minimal sufficient change with blast-radius assessment** (scope audit: where else can this precondition occur?).
- Add **targeted** validations/guards to prevent recurrence.
- **Escalate breadth** (wider refactor/layered defenses) only if evidence shows systemic risk or correlated failures.

## Exit Condition
Done when:
- Root cause is identified and validated (or best hypothesis + confidence + missing data listed),
- Fix is applied or clearly defined,
- Minimal recurrence defenses and monitoring are in place, or the next evidence step is explicit.
