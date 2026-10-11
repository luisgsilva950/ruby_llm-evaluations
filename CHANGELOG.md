# Changelog

## 0.1.0

- Ruby evaluation DSL for any callable agent, custom scored checks, and isolated per-case execution.
- First-class semantic accuracy and answer relevancy via caller-configured judges, with strict score/reason validation and captured failures.
- Ordered action-group evaluation covering group, name, arguments, missing calls, and unexpected calls; absent instrumentation remains distinct from an empty trace.
- Optional RubyLLM chat adapter with fresh case state, chronological tool traces, and reported usage across turns.
- PostgreSQL-only persistence through isolated ActiveRecord pools, immutable JSONB run snapshots, namespaced schema versions, and indexed chronological history.
- Compatible-baseline regression comparisons covering score changes, threshold failures, and agent/evaluator error transitions.
- CLI execution, history, regression gates, and text/Markdown/standalone HTML/JSON reports.
- Read-only local dashboard with filters, quality trends, dimension scores, baseline evidence, case/action details, and JSON downloads; supports Rails mount prefixes.
- Real PostgreSQL, CLI, Rails, and local RubyLLM HTTP integration tests; PostgreSQL-backed CI and an integration-tests-always directive.
- Vendor-agnostic `.agents` harness with GitHub and OMP pointers and shared Ruby/RubyLLM/persistence/dashboard/review guidance.
- Illustrated README with screenshots of actual persisted runs and generated reports.
