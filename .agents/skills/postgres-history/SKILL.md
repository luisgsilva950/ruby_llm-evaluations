---
name: postgres-history
description: Preserve durable immutable evaluation history and correctly ordered compatible-baseline regression comparisons.
---

# Persistent evaluation evidence

Read .agents/AGENTS.md, app/models/ruby_llm/evaluations/, db/migrate/, engine.rb, report.rb, and consumer callsites. PostgreSQL, SQLite, or MySQL through named ActiveRecord models is the evidence store, not a cache. Use the ActiveRecord-selected adapter without a PostgreSQL-only guard or storage abstraction. Consumers add their chosen driver; no driver is a mandatory gem dependency. Run UUID IDs are INSERT-only. Share the normal host pool; use model associations and short atomic saves after provider calls. Install the single schema migration into new Rails hosts; only the standalone CLI establishes its own Base connection, defaulting to sqlite3:ruby_llm_evaluations.sqlite3. Create exactly three domain tables: runs, case results, and metric results, with minimum_scores directly. Runs use a database-generated numeric PRIMARY KEY sequence and a unique string id for the model/public UUID API; case run_id foreign keys explicitly reference runs.id. Use jsonb on PostgreSQL and json elsewhere, initialize JSON values in models/runner instead of database defaults, and retain datetime precision 6. Existing applied PostgreSQL migrations/history remain unchanged; copied Rails migrations are not automatically rewritten. No legacy schema detection, payload imports, Store wrappers, anonymous model classes, separate pools, or automatic per-run migrations.

History ordering is chronological by started_at with database-generated sequence as the deterministic tie breaker. Baselines match suite, agent identity, and suite fingerprint, and must precede a historical current run. Dataset/rubric changes are not regressions. Missing or invalid explicit baselines must fail before expensive agent execution when possible.

Track threshold transitions, agent/evaluator error transitions, and score changes beyond configured tolerance. Never let tolerance conceal newly failed thresholds or newly errored evaluations. Do not duplicate one failure as both evaluator and case regression. Recovery can coexist with other remaining failures; keep the evidence explicit.

Smoke real SQLite, PostgreSQL, and MySQL persistence across close/reopen, ordering with out-of-order inserts, concurrent use, immutable UUID IDs, incompatible baselines, historical reports, and error transitions. Isolate temporary files/schemas/databases and remove only those test resources; never clear existing history. Report evidence, not just test counts.

Integration tests always: the final verifier exercises real SQLite-, PostgreSQL-, and MySQL-backed consumer flows for behavioral changes, including migrations, public API/CLI smoke, and persisted report/baseline evidence. Unit checks alone are insufficient; unavailable databases must not silently skip coverage.
