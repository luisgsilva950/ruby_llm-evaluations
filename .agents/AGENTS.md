# Project engineering harness

## Product and boundaries

Build `ruby_llm-evaluations`: a Ruby gem for code-defined evaluations of any callable agent, durable history, compatible-baseline regression reports, and a read-only local dashboard. Keep all four capabilities working together. Semantic accuracy, answer relevancy, and action-group correctness are first-class evaluation dimensions. RubyLLM is optional, not a required runtime dependency. This is not a Rails application.

## Design stance

Inspired by DHH's convention-over-configuration and integrated product design, and Akita on Rails' emphasis on understanding implementation costs and measuring performance. These are project decisions, not impersonation, quotations, or endorsement.

- Prefer ordinary Ruby, expressive names, cohesive objects, and obvious control flow.
- Build the concrete feature first. Extract demonstrated duplication; avoid service factories, dependency-injection containers, speculative adapters, and premature extensibility.
- Keep a useful default: one spec file, one PostgreSQL database, one executable, one localhost dashboard.
- Use standard libraries and existing dependencies before adding gems. No Rails, JavaScript build system, or background-job stack without a requirement.
- Optimize measured bottlenecks. Understand queries, allocations, I/O, and provider costs before claiming performance improvements.
- Prefer explicit boundaries and errors over magical coercion, hidden retries, swallowed exceptions, or fabricated evaluation success.

## Architecture map

Source paths are inside `lib/ruby_llm/evaluations/` unless otherwise noted.

- `suite.rb`: DSL, cases, stable evaluation-definition identity.
- `evaluators.rb`, `action_group.rb`: deterministic checks, semantic accuracy, answer relevancy, and action-group checks.
- `response.rb`, `actions.rb`, `adapters.rb`: responses, usage, action traces, and the optional RubyLLM chat adapter.
- `runner.rb`: case isolation, scoring, captured failures, aggregates.
- `store.rb`: ActiveRecord-backed append-only PostgreSQL history and chronological baseline lookup.
- `report.rb`: compatible comparisons and text/Markdown/HTML/JSON reports.
- `dashboard.rb`, `dashboard/`: read-only Rack-compatible HTTP surface and local assets.
- `cli.rb`, root `exe/`, root `examples/`: executable consumer workflow.

## Contracts to preserve

- Any object responding to `call(input)` can be an agent. Provider configuration and credentials stay in consumer code.
- Evaluators receive `(output, context)`. The context exposes case data and the full response. Return a Boolean, finite score in [0, 1], or `Assessment`. Thresholds are inclusive.
- Semantic accuracy compares factual meaning with a reference. Relevancy measures response to the actual user request. Neither is a synonym for lexical matching.
- Action groups are observed tool/API calls: group, action name, arguments, and order. Missing instrumentation is an error, not evidence of no action. Unexpected calls must reduce quality.
- Agent/evaluator failures are recorded, never converted into passing checks. Other cases/checks continue.
- Preserve caller-owned input and Ruby symbol/string distinctions. Persist JSON-portable data; never silently stringify unsupported objects.
- Fingerprints include dataset, Ruby input types, evaluator names/thresholds, and explicit suite version. Bump the version for scoring code/rubric changes; do not auto-hash Proc source.
- Baselines match suite, agent identity, and fingerprint. Historical reports never compare against future runs.
- Run IDs are immutable. PostgreSQL migrations preserve evidence and stay separate from host Rails schema migrations. Bind user-provided SQL values. Never switch or disconnect the host ActiveRecord connection pool.
- Treat output as untrusted. Escape HTML; keep the dashboard GET/HEAD-only and loopback by default. No external asset dependencies.
- Prompts, outputs, and reports may contain sensitive data. No credentials in fixtures, source, logs, or tracked databases.

## Working procedure

1. Read implementation and consumer callsites. Establish behavior and shared contracts before editing.
2. Make the smallest complete change. Migrate callers; no compatibility aliases or abandoned paths.
3. Demonstrate bugs before fixes. Keep focused behavior regression tests when useful.
4. Integration tests always. Every behavior change must add or update end-to-end integration coverage. Run the integration suite on every change, including harness changes, then `bundle exec rake test`. Unit tests supplement integration tests, never replace them. Assert behavior, not source wording or wiring.
5. Smoke the actual path using real PostgreSQL. Execute specs, reopen history, compare baselines, and inspect generated reports. Provider-transport fixtures may run over local HTTP; do not claim they prove model reasoning. For UI changes, launch the real dashboard and use a browser at desktop and narrow widths.
6. For packaging, run `gem build ruby_llm-evaluations.gemspec` and exercise the installed gem outside this checkout.
7. Update README/CHANGELOG for public changes. Remove temporary scaffolds. Report only observed verification and explicit limitations.

Follow the README PostgreSQL setup and export `DATABASE_URL` / `TEST_DATABASE_URL` before running these commands.

```sh
bundle install
bundle exec rake test
bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/support_eval.rb
AGENT_REVISION=regressed bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/support_eval.rb --fail-on-regression
bundle exec ruby -Ilib exe/ruby_llm-evaluations dashboard
```

The regressed example intentionally exits 1. Provider-backed examples are opt-in, require consumer credentials, and incur charges; never run them as default checks.

## Specialists and delegation

The vendor-agnostic source of truth is `.agents/`: shared instructions in `.agents/AGENTS.md`, specialists in `.agents/agents/*.md`, and reusable skills in `.agents/skills/*/SKILL.md`. GitHub and OMP files only point here. No pinned model, vendor-specific instruction dependencies, or global settings changes.

- `ruby-specialist`: DSL, Ruby object design, gem packaging, executable/API ergonomics.
- `ruby-llm-specialist`: provider-neutral adapters, RubyLLM response/tool semantics, semantic evaluation and judges.
- `persistence-specialist`: ActiveRecord/PostgreSQL migrations, immutable history, query order, regression comparisons.
- `dashboard-specialist`: safe rendering, read-only HTTP, accessibility, actual browser proof.
- `evaluation-reviewer`: independent consumer-visible correctness and security review.

Keep small work inline. Delegate only substantial independent slices with explicit file ownership, requirements, and shared contracts. No overlapping writes or independent product redesigns. Deliver concrete changes/findings, exercised commands and results, and any unresolved prerequisite. No completion claim without a consumer-path smoke.
