# RubyLLM Evaluations

**Write agent evaluations in Ruby. Run them against your agent. Keep the evidence in PostgreSQL. Detect regressions and inspect them in a dashboard.**

A Ruby gem, not a hosted service. Works with any object that responds to `call(input)`, including your own agent classes and RubyLLM chats. Rails applications can use the gem and mount its Rack-compatible dashboard.

## What you can evaluate

| Dimension | Question it answers | How it works |
| --- | --- | --- |
| Semantic accuracy | Does the answer agree with the reference in meaning and facts? | Caller-configured LLM judge; accepts paraphrases and penalizes contradictions and unsupported facts. |
| Answer relevancy | Does the answer address the user's request? | Independent judge rubric; an on-topic wrong answer can be relevant, while a true unrelated answer is not. |
| Action group | Did the agent invoke the expected tools/actions correctly? | Recorded group, action name, arguments, and order; missing, extra, or incorrect calls reduce the score. |
| Deterministic/custom checks | Does the answer satisfy an exact requirement? | Exact match, contains, regex, valid JSON, or your own Ruby scoring block. |

Semantic accuracy is **not** exact-string matching. Action correctness is **not** inferred from what the agent says it did.

## See the result

These are screenshots of the **running dashboard backed by actual persisted PostgreSQL runs**, not mockups. They use the offline support-agent example: one reference run, followed by a deliberately regressed run. No external model was called to produce these screenshots.

### History and quality trends

Filter by suite and agent, inspect previous runs, and follow comparable quality scores over time. Different evaluation definitions produce separate trend series.

![Working evaluation history dashboard with a declining quality trend and persisted runs](docs/images/dashboard-history.png)

### Regression report

A run is compared with its previous matching baseline. The report identifies which checks changed, rather than just showing a lower overall average.

![Working dashboard showing a regression, baseline deltas, and per-dimension scores](docs/images/dashboard-regression.png)

### Evidence for a failed case

The example gives the wrong return window and looks up the wrong policy. The dashboard shows the answer and the expected/observed action arguments side by side.

![Failed case with input, reference, answer, scores, and expected versus observed action groups](docs/images/dashboard-case.png)

## Quick start: no API key needed

Requirements: **Ruby 3.2+**, PostgreSQL, and Bundler. Docker Compose is an optional way to run development PostgreSQL.

From this checkout:

```sh
bundle install

docker compose up -d --wait
export DATABASE_URL='postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations'

# Run the offline agent and save its reference results.
bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/support_eval.rb \
  --metadata '{"revision":"reference"}'

# Introduce an incorrect answer and wrong action arguments.
# Exit status 1 is intentional: the evaluation detects the regression.
AGENT_REVISION=regressed bundle exec ruby -Ilib exe/ruby_llm-evaluations \
  run examples/support_eval.rb --fail-on-regression \
  --metadata '{"revision":"regressed"}'

# Inspect history, then start the dashboard.
bundle exec ruby -Ilib exe/ruby_llm-evaluations history
bundle exec ruby -Ilib exe/ruby_llm-evaluations dashboard
```

Open **http://127.0.0.1:4567**. Stop the dashboard with Ctrl-C. Results remain in PostgreSQL and survive process restarts.

The Compose service binds PostgreSQL to loopback on port **55432** and uses passwordless development authentication. **Do not use this configuration in production.** Its named volume preserves your data. `docker compose stop` stops the service without deleting the volume.

For your own PostgreSQL service, set `DATABASE_URL` to its connection URL. The gem creates its namespaced tables on first use; the database must already exist, and the connection must have the necessary schema privileges. Without `DATABASE_URL`, the default is `postgresql://localhost/ruby_llm_evaluations`.

### Install the built gem

This checkout can be packaged and installed locally; these commands do not assume the gem has been published to RubyGems:

```sh
gem build ruby_llm-evaluations.gemspec
gem install ./ruby_llm-evaluations-0.1.0.gem
ruby_llm-evaluations --help
```

In an application's Gemfile during local development:

```ruby
gem "ruby_llm-evaluations", path: "/path/to/ruby_llm-evaluations"
```

`ruby_llm` is an optional integration. Add it to the consuming application's Gemfile only when you use RubyLLM agents or judges. Runtime storage uses `activerecord` and `pg`; Rails itself is not a runtime dependency.

## 1. Define an evaluation as code

An evaluation is a suite: a stable name, an agent callable, evaluators, and test cases. Save this complete example as `policy_eval.rb`:

```ruby
require "ruby_llm/evaluations"

E = RubyLLM::Evaluations
policies = { "return_policy" => "Returns are accepted within 30 days." }
agent = ->(input) { policies.fetch(input) }

E.define("return policy", agent: agent, agent_name: "PolicyAgent", version: "1") do
  evaluate :correctness, using: E::Evaluators.exact_match

  test "return window",
       input: "return_policy",
       expected: "Returns are accepted within 30 days."
end
```

```sh
ruby_llm-evaluations run policy_eval.rb
```

The spec file must return a `RubyLLM::Evaluations::Suite`; `define` returns one. Spec files execute **trusted Ruby code** with the permissions of your process. They are not sandboxed.

For an existing agent, supply the object directly if it implements `call(input)`, or adapt its method with a lambda. Provider configuration, credentials, and business logic remain in your application.

The same generic callable is reused across cases. The runner copies case data but does not reset agent internals. Construct a fresh stateful agent inside your callable when cases must be independent; the RubyLLM adapter uses a fresh-chat factory for this reason.

Inputs, reference answers, outputs, and metadata must be JSON-portable. Ruby symbol keys/values are supported and normalized in persisted snapshots; their Ruby type distinctions are preserved in the evaluation fingerprint. Unsupported objects fail explicitly rather than being silently stringified.

### Custom evaluators

An evaluator receives `(output, context)`. The context exposes `id`, `name`, `input`, `expected`, `expected_actions`, `metadata`, and the full `response`.

Return `true`/`false`, a finite numeric score between **0 and 1**, or an `Assessment` with a reason:

```ruby
evaluate :conciseness, threshold: 0.8 do |output, context|
  score = output.split.size <= context.metadata.fetch(:max_words) ? 1.0 : 0.0
  E::Assessment.new(score: score, reason: "Checked the answer's word budget")
end

test "short return policy", input: "return_policy",
     expected: "Returns are accepted within 30 days.", metadata: { max_words: 12 }
```

Thresholds are inclusive. Built-ins are `exact_match`, `contains`, `matches(/pattern/)`, and `valid_json`.

## 2. Evaluate semantic accuracy and relevancy

Both semantic evaluators accept a **judge callable**. The framework supplies a rubric and evaluation data. The judge returns JSON with a numeric `score` in `[0, 1]` and a nonempty string `reason`:

```json
{"score": 0.9, "reason": "The answer preserves the reference facts and addresses the question."}
```

Once a judge is configured, add the two checks inside your suite:

```ruby
evaluate :semantic_accuracy,
         using: E::Evaluators.semantic_accuracy(judge: judge), threshold: 0.9

evaluate :answer_relevancy,
         using: E::Evaluators.answer_relevancy(judge: judge), threshold: 0.9
```

Semantic accuracy requires a nonempty `expected` reference for each case. Relevancy evaluates the actual request independently of reference correctness. `Evaluators.llm_judge(judge:, rubric:)` supports your own rubric.

Malformed judge JSON, invalid scores/reasons, and judge exceptions are recorded as **evaluation errors**, not favorable defaults. Model judgments are nondeterministic: calibrate thresholds against human-reviewed examples. Marking evaluation data as untrusted does not eliminate prompt-injection risks.

### Complete RubyLLM example with all three dimensions

[`examples/semantic_actions_eval.rb`](examples/semantic_actions_eval.rb) contains a real read-only `RubyLLM::Tool`, a fresh agent chat per case, separate judge chats, and semantic/relevancy/action checks.

This example uses OpenAI through RubyLLM; the framework and judge interface are provider-neutral. It makes real provider requests and incurs charges:

```sh
export OPENAI_API_KEY='your-key'
export EVAL_MODEL='gpt-4.1-mini'
export EVAL_JUDGE_MODEL='gpt-4.1-mini'

bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/semantic_actions_eval.rb \
  --metadata '{"agent_model":"gpt-4.1-mini","judge_model":"gpt-4.1-mini"}'
```

The agent model must support the example's tool-choice options. The default test suite and offline quick start never call external providers.

## 3. Evaluate action groups

For any Ruby agent, return an instrumented response alongside the answer:

```ruby
E::Response.new(
  output: "Order 42 has shipped.",
  actions: [
    { group: "orders", name: "lookup_order", arguments: { id: 42 } }
  ],
  input_tokens: 120,
  output_tokens: 18,
  cost: 0.0002,
  metadata: { model: "your-model" }
)
```

Declare the expected invocation trace in the case:

```ruby
evaluate :action_group, using: E::Evaluators.action_group

test "track order", input: "Track order 42",
     expected: "Order 42 has shipped.",
     expected_actions: [
       { group: "orders", name: "lookup_order", arguments: { id: 42 } }
     ]
```

Expected actions must name their group. Scoring compares actions **at each position** using group, name, and exact arguments. The score is matching positions divided by the larger trace length. The default threshold `1.0` therefore requires the full ordered trace, with no extra calls.

- `actions: []` means instrumentation observed **no actions**.
- `actions: nil` means instrumentation is **missing**; the action evaluator errors.
- `expected_actions: []` explicitly expects no calls; an unexpected call fails.
- Missing `expected_actions` is a configuration error for the action evaluator.

These are invocation checks, not proof that every tool produced the correct business result. Record the calls your application actually invokes; do not synthesize traces from answer text.

The RubyLLM adapter extracts chronological tool calls from chat messages and sums reported assistant usage across turns:

```ruby
agent = E::Adapters.ruby_llm_chat(action_groups: { "lookup_order" => "orders" }) do
  RubyLLM.chat(model: ENV.fetch("EVAL_MODEL")).with_tool(LookupOrderTool)
end
```

The factory must return a fresh chat per input. Unmapped tool names have an unknown (`nil`) group, not an invented one. Plain RubyLLM messages are also normalized automatically, but a final message alone does not provide the preceding action trace.

## 4. Persist runs and detect regressions

Every completed evaluation saves a new immutable run in PostgreSQL, including cases, outputs, references, action traces, scores, reasons, errors, metadata, and reported usage.

The automatic baseline is the most recent **earlier** run matching:

1. Suite name.
2. Agent name.
3. Evaluation-definition fingerprint.

The fingerprint includes cases and their Ruby data types, references, expected actions, metadata, evaluator names/thresholds, and the explicit suite `version`. Changed datasets or thresholds are not compared as if they were regressions.

**Bump `version` when changing custom evaluator logic, a rubric, or judge semantics/configuration.** Callable implementation changes cannot be fingerprinted reliably. Keep `agent_name` stable across agent revisions you want to compare; record revision/model/prompt information in run metadata.

Regressions include score decreases beyond tolerance, newly failed thresholds, and new agent/evaluator errors. Tolerance never hides newly failed thresholds or errors.

```sh
ruby_llm-evaluations run policy_eval.rb --fail-on-regression --tolerance 0.02
ruby_llm-evaluations run policy_eval.rb --baseline RUN_ID --fail-on-regression
ruby_llm-evaluations history --suite 'return policy' --agent PolicyAgent --limit 50
```

An explicit missing or incompatible baseline is rejected before executing the agent. Historical reports never select future runs as automatic baselines.

### Understand the scores and exit codes

- A case passes only if every evaluator passes and there are no errors.
- Case quality is the mean evaluator score; evaluation errors contribute zero. Agent errors give the case a zero score.
- Run quality is the mean case quality. Pass rate is the fraction of cases that pass.
- Dashboard dimension means include scored assessments only and show error counts separately.
- `status: completed` means execution finished, **not** that the agent passed.
- Token/cost totals include only reported agent values. A zero total does not prove zero usage/cost; judge usage is not included. Supply `Response#cost` in USD when using the dashboard's cost display.

| CLI run exit code | Meaning |
| --- | --- |
| `0` | Cases passed; requested regression gate passed. |
| `1` | A case failed/errored, or `--fail-on-regression` detected a regression even though thresholds still passed. |
| `2` | Invalid spec, options, baseline, or configuration. |

## 5. Generate reports

Text is the default. Export the latest run or pass a run ID from history:

```sh
mkdir -p reports
ruby_llm-evaluations report --format html --output reports/agent.html
ruby_llm-evaluations report --format markdown --output reports/agent.md
ruby_llm-evaluations report --format json --output reports/agent.json
ruby_llm-evaluations report RUN_ID --baseline BASELINE_ID --format text
```

HTML reports are standalone and escape agent output. JSON includes the full run plus `comparison` (`null` when no compatible baseline exists). The dashboard also offers **Download JSON report**.

This image is the baseline section of a generated HTML report from the same PostgreSQL run:

![Actual generated standalone HTML report showing baseline and per-evaluator regressions](docs/images/html-report.png)

### Programmatic execution and reporting

```ruby
store = E::Store.new(ENV.fetch("DATABASE_URL"))
begin
  run = E::Runner.new(store: store).run(suite, metadata: { revision: "candidate" })
  baseline = store.latest(
    suite: run.fetch("suite"), agent: run.fetch("agent"),
    suite_digest: run.fetch("suite_digest"), before_id: run.fetch("id")
  )
  report = E::Report.new(run, baseline: baseline, tolerance: 0.02)
  File.write("agent-report.html", report.to_html)
ensure
  store.close
end
```

For execution only, `E.run(suite, database_url: ENV.fetch("DATABASE_URL"), metadata: {})` opens and closes the store for you and returns the persisted run hash.

## Use from Rails

Use your application's PostgreSQL ActiveRecord configuration without changing its connection pool:

```ruby
# config/routes.rb
require "ruby_llm/evaluations"

evaluation_store = RubyLLM::Evaluations::Store.new(
  ActiveRecord::Base.connection_db_config.configuration_hash
)

Rails.application.routes.draw do
  mount RubyLLM::Evaluations::Dashboard.new(store: evaluation_store) => "/evaluations"
end
```

Visit `/evaluations`. Stylesheets, filtering, detail links, baseline links, and downloads respect the mount path. Keep the mounted store alive for the application's lifetime; close it on application shutdown if your lifecycle manages explicit shutdown hooks.

The store uses dedicated ActiveRecord models/pools and namespaced PostgreSQL tables (`ruby_llm_evaluations_runs`, `ruby_llm_evaluations_schema_versions`). It does not replace the host connection or use the host's Rails migration-version table.

The dashboard has **no built-in authentication**. Protect mounted routes with your application's authentication/authorization or a trusted reverse proxy before exposing sensitive evaluation data. The standalone server binds to loopback by default and accepts only GET/HEAD.

## Development: integration tests always

Every behavioral change must add or update end-to-end coverage. Run integration tests on every change; unit tests do not replace them. The full test task includes integration tests.

Create a separate test database once, then run the suite:

```sh
docker compose exec -T postgres createdb -U postgres ruby_llm_evaluations_test
export TEST_DATABASE_URL='postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations_test'

bundle exec rake integration
bundle exec rake test
```

Tests create and remove their own random PostgreSQL schemas; they do not clear the development database. The test role needs schema-creation privileges. For an existing PostgreSQL installation, create the test database with its normal administration tools and set `TEST_DATABASE_URL` accordingly.

Coverage includes real PostgreSQL history/reopening/concurrency, CLI regression gates, action arguments/groups/order, Rails mounting, and actual RubyLLM agent/tool/judge HTTP round trips against a bounded local fixture. Fixtures verify transport and orchestration, **not model reasoning quality**. No live API keys are required. GitHub Actions provisions PostgreSQL and runs the full suite.

For UI changes, also run the dashboard and inspect desktop/narrow layouts, keyboard access, filters, chart-point navigation, and downloaded reports in an actual browser.

### Vendor-agnostic AI harness

Shared instructions and specialist workflows live under **`.agents/`**, inspired by DHH's convention-over-configuration and Akita on Rails' measured, implementation-aware engineering. No model or vendor is pinned.

- [Shared project directives](.agents/AGENTS.md).
- `.agents/agents/`: Ruby, RubyLLM, PostgreSQL/ActiveRecord, dashboard, and review specialists.
- `.agents/skills/`: reusable Ruby/gem, LLM-evaluation, persistence, and dashboard workflows.
- Root `AGENTS.md`, `.github/copilot-instructions.md`, and GitHub/OMP specialist adapters point to the shared harness; OMP skill links point to the same skill directories.

### Screenshot provenance

All images in `docs/images/` were captured from the running application or generated report using the offline quick-start spec and its two persisted PostgreSQL runs. Run IDs/timestamps vary in your environment. The narrow dashboard view is also available:

![Actual working dashboard at a narrow mobile viewport](docs/images/dashboard-mobile.png)

## Data and security boundaries

Specs execute trusted code. Agent answers and judge data are untrusted content. Prompts, reference answers, traces, errors, and metadata are retained in your database and exported reports; redact sensitive information before evaluation and manage retention/backups in your deployment. Do not commit credentials or production data.

No hosted backend or external dashboard assets are used. The framework adds no provider retries or automatic success fallbacks; provider-library behavior remains your configuration responsibility.

## License

MIT. See [LICENSE](LICENSE).
