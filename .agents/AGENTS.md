# Project engineering harness

## Product and boundaries

Build `ruby_llm-agent-evaluations`: a Ruby gem and optional Rails engine for question-first evaluations of any callable agent, durable PostgreSQL/SQLite/MySQL history through ActiveRecord, compatible-baseline regression reports, and a read-only dashboard. Keep all four capabilities working together. Semantic accuracy, answer relevancy, and action-group correctness are first-class dimensions. RubyLLM is optional; Rails hosts use their normal ActiveRecord connection and migration lifecycle. Consumers add their chosen database driver; no driver is a mandatory gem dependency.

## Design stance

Inspired by DHH's convention-over-configuration and integrated product design, and Akita on Rails' emphasis on understanding implementation costs and measuring performance. These are project decisions, not impersonation, quotations, or endorsement.

- Prefer ordinary Ruby, expressive names, cohesive objects, and obvious control flow.
- Build the concrete feature first. Extract demonstrated duplication; avoid service factories, dependency-injection containers, speculative adapters, and premature extensibility.
- Keep a useful default: one spec file, one local SQLite database (`sqlite3:ruby_llm_evaluations.sqlite3` for the standalone CLI), one executable, one localhost dashboard.
- Use standard libraries and existing dependencies before adding gems. Use ordinary ActiveRecord models and Rails engine conventions; no JavaScript build system or background-job stack without a requirement.
- Optimize measured bottlenecks. Understand queries, allocations, I/O, and provider costs before claiming performance improvements.
- Prefer explicit boundaries and errors over magical coercion, hidden retries, swallowed exceptions, or fabricated evaluation success.

## Architecture map

Source paths are inside `lib/ruby_llm/evaluations/` unless otherwise noted.

- `suite.rb`: question/expected-answer DSL, declarative minimum_scores, metadata, and typed definition fingerprints.
- `evaluators.rb`, `action_group.rb`: deterministic checks, semantic accuracy, answer relevancy, and action-group checks.
- `response.rb`, `actions.rb`, `adapters.rb`: responses, usage, action traces, and the optional RubyLLM chat adapter.
- `runner.rb`: case isolation, scoring, captured failures, aggregates.
- Root `app/models/ruby_llm/evaluations/`: named Run, CaseResult, and MetricResult models, append-only evidence, associations, and chronological baseline lookup.
- Root `db/migrate/`, `config/routes.rb`, and `engine.rb`: standard Rails migration, autoloading, and routing lifecycle.
- `report.rb`: compatible comparisons and text/Markdown/HTML/JSON reports.
- `dashboard.rb`, `dashboard/`: read-only Rack-compatible HTTP surface and local assets.
- `cli.rb`, root `exe/`, root `examples/`: executable consumer workflow.

## Contracts to preserve

- Any object responding to `call(question)` can be an agent. Provider configuration and credentials stay in consumer code.
- Evaluators receive `(output, context)`. The context exposes case data and the full response. Return a Boolean, finite score in [0, 1], or `Assessment`. Thresholds are inclusive.
- Question minimum_scores map metric names to absolute inclusive thresholds on every run, including the first; expected_answer is the reference, not a numeric target or string-similarity percentage. Regression separately compares observed scores to an earlier compatible baseline, so passing a minimum can still regress. Changing minimum_scores changes the definition fingerprint.
- Semantic accuracy compares factual meaning with a reference. Relevancy measures response to the actual user request. Neither is a synonym for lexical matching.
- The optional judge is a RubyLLM::Agent class supplied to the Suite constructor, instantiated fresh per assessment; never add global judge configuration or per-evaluator judge wrappers. Without a judge, skip LLM metrics. No computed metrics means not_evaluated with null quality/pass rate, never a passing or zero-quality substitute. Compare only equivalent computed metric sets.
- Report#export owns file writing; callers and CLI must not assemble their own File.write(report.to_html) workflow.
- Action groups are observed tool/API calls: group, action name, arguments, and order. Missing instrumentation is an error, not evidence of no action. Unexpected calls must reduce quality.
- Agent/evaluator failures are recorded, never converted into passing checks. Other cases/checks continue.
- Preserve caller-owned input and Ruby symbol/string distinctions. Persist JSON-portable data; never silently stringify unsupported objects.
- Fingerprints include question data, expected answers/actions, minimum_scores names/thresholds, metadata, Ruby types, and explicit suite version. Bump the version for scoring code/rubric/judge changes; do not auto-hash Proc source.
- Baselines match suite, agent identity, and fingerprint. Historical reports never compare against future runs.
- Run IDs are immutable UUID strings. Named ActiveRecord models share the host pool and use the adapter selected by ActiveRecord, without PostgreSQL-only guards or a separate storage abstraction. Engine migrations are installed and applied through normal Rails tasks; standalone CLI users explicitly run db:migrate. New-project setup creates exactly three domain tables: runs, case results, and metric results, with minimum_scores directly. Runs have a database-generated numeric PRIMARY KEY sequence and a unique string id used by the model/public UUID API; case run_id foreign keys explicitly reference runs.id. Use PostgreSQL jsonb and json elsewhere, initialize JSON values in models/runner rather than database defaults, and retain datetime precision 6. History orders by started_at then sequence. Do not add legacy schema detection or import paths. Existing applied PostgreSQL migrations and evidence remain unchanged; copied Rails migrations are not automatically rewritten, and new hosts install the current migration. Never establish or disconnect a host pool during library execution. Bind user-provided SQL values.
- Treat output as untrusted. Escape HTML; keep the dashboard GET/HEAD-only and loopback by default. No external asset dependencies.
- Prompts, outputs, and reports may contain sensitive data. No credentials in fixtures, source, logs, or tracked databases.

## Working procedure

1. Read implementation and consumer callsites. Establish behavior and shared contracts before editing.
2. Make the smallest complete change. Migrate callers; no compatibility aliases or abandoned paths.
3. Demonstrate bugs before fixes. Keep focused behavior regression tests when useful.
4. Integration tests always. Every behavior change must add or update end-to-end integration coverage for real SQLite, PostgreSQL, and MySQL. The final verifier runs the integration suite on every change, including harness changes, then `bundle exec rake test`; never silently skip an unavailable database. Unit tests supplement integration tests, never replace them. Assert behavior, not source wording or wiring.
5. Smoke the actual public API and CLI using real SQLite, PostgreSQL, and MySQL with isolated test files/schemas/databases. Execute specs, reopen history, compare baselines, and inspect generated reports on each adapter. Preserve development history and clean up only temporary test resources. Provider-transport fixtures may run over local HTTP; do not claim they prove model reasoning. For UI changes, launch the real dashboard and use a browser at desktop and narrow widths.
6. For packaging, run `gem build ruby_llm-agent-evaluations.gemspec` and exercise the installed gem outside this checkout.
7. Update README/CHANGELOG for public changes. Remove temporary scaffolds. Report only observed verification and explicit limitations.

Follow the README development setup: `docker compose up -d postgres mysql`, export `TEST_DATABASE_URL=postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations_test` and `TEST_MYSQL_DATABASE_URL=mysql2://root:dev-only@127.0.0.1:53306/mysql`, and create the PostgreSQL test database once. SQLite tests use temporary files and need no service. The standalone smoke below defaults to the local SQLite file; repeat with DATABASE_URL selecting isolated PostgreSQL and MySQL databases.

```sh
bundle install
bundle exec rake integration
bundle exec rake test
bundle exec ruby -Ilib exe/ruby_llm-agent-evaluations db:migrate
bundle exec ruby -Ilib exe/ruby_llm-agent-evaluations run examples/support_eval.rb
AGENT_REVISION=regressed bundle exec ruby -Ilib exe/ruby_llm-agent-evaluations run examples/support_eval.rb --fail-on-regression
bundle exec ruby -Ilib exe/ruby_llm-agent-evaluations dashboard
```

The regressed example intentionally exits 1. Provider-backed examples are opt-in, require consumer credentials, and incur charges; never run them as default checks.

## Specialists and delegation

The vendor-agnostic source of truth is `.agents/`: shared instructions in `.agents/AGENTS.md`, specialists in `.agents/agents/*.md`, and reusable skills in `.agents/skills/*/SKILL.md`. GitHub and OMP files only point here. No pinned model, vendor-specific instruction dependencies, or global settings changes.

- `ruby-specialist`: DSL, Ruby object design, gem packaging, executable/API ergonomics.
- `ruby-llm-specialist`: provider-neutral adapters, RubyLLM response/tool semantics, semantic evaluation and judges.
- `persistence-specialist`: portable ActiveRecord PostgreSQL/SQLite/MySQL migrations, immutable history, query order, regression comparisons.
- `dashboard-specialist`: safe rendering, read-only HTTP, accessibility, actual browser proof.
- `evaluation-reviewer`: independent consumer-visible correctness and security review.

Keep small work inline. Delegate only substantial independent slices with explicit file ownership, requirements, and shared contracts. No overlapping writes or independent product redesigns. Deliver concrete changes/findings, exercised commands and results, and any unresolved prerequisite. No completion claim without a consumer-path smoke.
