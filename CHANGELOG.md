# Changelog

## Unreleased

- Rename the question keyword and evaluation context field from `criteria` to `minimum_scores`, with no compatibility alias. Update specifications and custom evaluators to use the new name. Scores use absolute inclusive per-metric minimums on every run, including the first; previous-run regression comparison remains separate. Equivalent definitions retain their historical fingerprints, while changing metric names or thresholds changes the fingerprint.
- Keep Ruby 3.2 CI dependencies compatible by constraining development RBS below 4; use the Node 24 checkout action.
- Preserve existing PostgreSQL history while migrating stored minimum-score names. Rails hosts upgrade with `bin/rails ruby_llm_evaluations:install:migrations` followed by `bin/rails db:migrate`; standalone users run `ruby_llm-evaluations db:migrate`.

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
