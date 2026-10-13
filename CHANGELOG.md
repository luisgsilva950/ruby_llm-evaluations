# Changelog

## Unreleased

- Add a native A2UI 0.8 metric: official catalog-backed JSON Schema validation and question-level assertions for surface, root, catalog, component type, and nested props. Correct text cannot conceal invalid UI.
- Support custom catalogs as Ruby Hashes or local JSON files, immutable catalog snapshots and compatible-baseline fingerprints, and offline embedded schema references. Add `json_schemer` and bundle pinned Apache-2.0 A2UI schemas.
- Validate ordered/incremental messages, deleted surfaces, component references, and earlier invalid evidence; persist actionable diagnostics through existing history and reports. Replace the example’s manual JSONL comparison and verify native flows on SQLite, PostgreSQL, and MySQL. No new tables or migrations.

## 0.3.0 — 2026-10-12

- Evaluate structured response components independently from text, with protocol/version checks and application-defined validators. Preserve component evidence in history, exports, and the dashboard using existing tables.
- Add optional capture for actual tools without changing returns or callbacks; retain observed tool names and arguments. Plain response components do not fabricate tool provenance.
- Include a standalone A2UI 0.8 example with a plain Ruby renderer and no RubyLLM dependency. Correct text does not conceal incorrect or missing UI.
- Simplify component validation and capture, improve the README, and verify SQLite/PostgreSQL/MySQL regression flows. No new migrations or runtime dependencies.

## 0.2.2

- Support PostgreSQL, SQLite, and MySQL 8.0+ through the ActiveRecord-selected adapter and one migration creating exactly three evaluation tables. Preserve UUID run IDs, append-only evidence, foreign keys, and chronological baseline ordering. MySQL uses binary, non-padding collation to preserve exact agent, case, and metric identities.
- Remove the PostgreSQL-only migration guard and mandatory `pg` dependency. Consumers add their chosen database driver; Rails continues using its normal host pool and migration tasks, while the standalone CLI defaults to `sqlite3:ruby_llm_evaluations.sqlite3`.
- Keep existing applied PostgreSQL migrations and saved history unchanged. Rails migrations already copied into a host are not automatically rewritten; new hosts install the current engine migration. No schema reset, history deletion, or legacy upgrade is required for portability.
- Add real SQLite, PostgreSQL, and MySQL consumer coverage and document driver selection, local quick starts, and isolated cross-adapter development checks.

## 0.2.1

- Simplify new-project setup to one migration creating only runs, case results, and metric results, with `minimum_scores` from the start. Remove legacy schema detection, payload copying, temporary migration models, and the intermediate column-rename migration. Legacy database upgrades are no longer supported.

## 0.2.0

- Publish this project as `ruby_llm-agent-evaluations` to avoid the separately owned RubyGems package. Rename the executable and gemspec; preserve `RubyLLM::Evaluations`, `ruby_llm/evaluations`, Rails migration tasks, and PostgreSQL history. Version 0.2.0 is the first RubyGems release under the new name; the earlier section records this project's development history.
- Add `script/publish` with integration/full-suite gates, isolated installed-package CLI/PostgreSQL smoke, manifest checks, and an upload-free `--dry-run`. Publication requires a clean committed tree and RubyGems credentials.
- Add strict question-scoped API replay for Net::HTTP and Faraday: ordered one-use request assertions, inline JSON or exact-byte JSON files, explicit live-host allowances, and persisted redacted mismatch evidence. Fixture definitions and response-byte hashes participate in compatible-baseline fingerprints; suites without replay keep their fingerprints.
- Add a large-response evaluation with independent answer, action-argument, and model-facing tool-result budget checks, a bounded/raw-output regression, and an opt-in OpenAI example.
- Rename the question keyword and evaluation context field from `criteria` to `minimum_scores`, with no compatibility alias. Update specifications and custom evaluators to use the new name. Scores use absolute inclusive per-metric minimums on every run, including the first; previous-run regression comparison remains separate. Equivalent definitions retain their historical fingerprints, while changing metric names or thresholds changes the fingerprint.
- Keep Ruby 3.2 CI dependencies compatible by constraining development RBS below 4; use the Node 24 checkout action.
- Preserve existing PostgreSQL history while migrating stored minimum-score names. Rails hosts upgrade with `bin/rails ruby_llm_evaluations:install:migrations` followed by `bin/rails db:migrate`; standalone users run `ruby_llm-agent-evaluations db:migrate`.

## 0.1.0

- Question-first Ruby specifications with expected answers, declarative minimum metric scores, important-fact metadata, and optional custom scored checks.
- Semantic accuracy and answer relevancy use an optional RubyLLM::Agent class passed to the suite constructor, with fresh conversations and strict score/reason validation. No global judge setup; absent judges skip LLM metrics, leaving unassessed quality null rather than fabricating a pass.
- Ordered action-group evaluation covering group, name, arguments, missing calls, and unexpected calls; absent instrumentation remains distinct from an empty trace.
- Optional RubyLLM chat adapter with fresh case state, chronological tool traces, and reported usage across turns.
- PostgreSQL history through named Run, CaseResult, and MetricResult ActiveRecord models sharing the host pool; normal Rails engine migrations preserve legacy evidence, with explicit standalone db:migrate.
- Compatible-baseline regression comparisons covering score changes, threshold failures, and agent/evaluator error transitions.
- CLI execution, history, regression gates, and text/Markdown/standalone HTML/JSON reports; Report#export owns file output with format inference.
- Read-only local dashboard and Rails engine with filters, quality trends, dimension scores, baseline evidence, question/action details, and JSON downloads; standard Rails routes and mount prefixes.
- Real PostgreSQL, CLI, Rails, and local RubyLLM HTTP integration tests; PostgreSQL-backed CI and an integration-tests-always directive.
- Vendor-agnostic `.agents` harness with GitHub and OMP pointers and shared Ruby/RubyLLM/persistence/dashboard/review guidance.
- Illustrated README with screenshots of actual persisted runs and generated reports.
