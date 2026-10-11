---
name: postgres-history
description: Preserve durable immutable evaluation history and correctly ordered compatible-baseline regression comparisons.
---

# Persistent evaluation evidence

Read .agents/AGENTS.md, store.rb, report.rb, and their consumer callsites. PostgreSQL through ActiveRecord is the evidence store, not a cache. Run IDs are INSERT-only. Use transactions, schema versions, bound parameters, and explicit unsupported-schema errors. Keep connection pools and migrations isolated from a host Rails application.

History ordering is chronological with a deterministic tie breaker. Baselines match suite, agent identity, and suite fingerprint, and must precede a historical current run. Dataset/rubric changes are not regressions. Missing or invalid explicit baselines must fail before expensive agent execution when possible.

Track threshold transitions, agent/evaluator error transitions, and score changes beyond configured tolerance. Never let tolerance conceal newly failed thresholds or newly errored evaluations. Do not duplicate one failure as both evaluator and case regression. Recovery can coexist with other remaining failures; keep the evidence explicit.

Smoke persistence across close/reopen, ordering with out-of-order inserts, concurrent use, immutable IDs, incompatible baselines, historical reports, and error transitions. Remove temporary databases. Report evidence, not just test counts.

Integration tests always: exercise the real PostgreSQL-backed consumer flow for behavioral changes. Unit checks alone are insufficient.
