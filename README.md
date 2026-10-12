# RubyLLM Evaluations

Write questions and expected answers in Ruby, declare what matters, and keep evaluation evidence in PostgreSQL. Compare compatible runs and inspect answers, metrics, errors, and action traces in a read-only dashboard.

Works with any callable agent. RubyLLM is optional; Rails applications use named ActiveRecord models sharing their normal host connection pool.

## Question-first specifications

Pass an optional RubyLLM judge agent class directly to the suite constructor. There is no global judge configuration or judge wrapper to build. Your application supplies the agent being evaluated and, when desired, its judge class:

~~~ruby
require "ruby_llm/evaluations"

suite = RubyLLM::Evaluations.define("Customer support", agent: support_agent, judge: SupportJudgeAgent) do
  question "How long do I have to return an item?",
           expected_answer: "You can return it within 30 days.",
           minimum_scores: { semantic_accuracy: 0.9, answer_relevancy: 0.9 },
           metadata: { important_facts: ["The return deadline is 30 days."] }
end
~~~

| Spec field | Meaning |
| --- | --- |
| `question` | The actual request sent to your agent. |
| `expected_answer` | A reference answer string, not a numeric score; paraphrases can pass semantic scoring. |
| `minimum_scores` | A map of metric names to absolute, inclusive numeric passing thresholds from 0 to 1, applied on every run, including the first. |
| `metadata` | Evaluation context, such as the essential facts that the judge must check. |

`minimum_scores: { semantic_accuracy: 0.9 }` means that the calculated semantic-accuracy score must be at least 0.9, even on the first run when no baseline exists. It does not compare against a previous run, and 0.9 is not a promise of 90% string similarity with expected_answer: the semantic judge scores factual meaning against that reference.

The library creates the selected metrics per question. Semantic accuracy measures factual meaning, accepting paraphrases while penalizing contradictions, unsupported additions, and omitted essential facts. Answer relevancy independently measures responsiveness: a wrong but on-topic answer can be relevant. Metadata is supplied as untrusted evaluation context; important_facts identifies factual priorities, not executable prompt instructions.

Without explicit suite-level evaluate definitions, omitted minimum_scores defaults to semantic_accuracy and answer_relevancy at 0.9. These metrics run only when a judge is supplied. With no judge, LLM-as-judge metrics are not calculated; deterministic and action-group checks still run. No substitute or fabricated score is provided. Explicit minimum_scores chooses named standard/custom metrics per question. Thresholds are inclusive.

Questions accept optional name:, id:, and expected_actions:. Names default to question text (or a generated label for structured questions); IDs default to names and must be unique. Question/reference/metadata/output data must be JSON-portable. Symbol keys/values retain Ruby distinctions in fingerprints and agent calls; persisted JSON normalizes them. Unsupported objects fail explicitly. Specs execute trusted Ruby, not sandboxed code, and must return a Suite; define returns one.

## Strict API replay

Declare fixtures inside a question block to exercise real HTTP clients without contacting the API. This complete spec needs the ordinary PostgreSQL setup below, but no provider credentials:

~~~ruby
require "net/http"
require "json"
require "ruby_llm/evaluations"

E = RubyLLM::Evaluations
shipping_agent = ->(_question) do
  response = Net::HTTP.get_response(URI("https://shipping.example/orders?id=42"))
  JSON.parse(response.body).fetch("status")
end

E.define("Shipping API", agent: shipping_agent, agent_name: "ShippingAgent") do
  evaluate :exact, using: E::Evaluators.exact_match
  question "Track order 42", expected_answer: "ready" do
    api_interactions do
      expect_request(method: :get, url: "https://shipping.example/orders",
                     query: { id: "42" })
        .respond_with(status: 200, headers: { "Content-Type" => "application/json" },
                      json: { status: "ready" })
    end
  end
end
~~~

Save it as `shipping_eval.rb`, then run `ruby_llm-evaluations run shipping_eval.rb` after migrations. [examples/api_replay_eval.rb](examples/api_replay_eval.rb) also demonstrates file responses. Replay supports Net::HTTP and Faraday through standard WebMock-supported transports; it does not replace your agent or HTTP client. Only the agent call is wrapped, not evaluators or judges. Existing mock registrations, network configuration, and enabled adapters are restored after each case, including failures.

Run the bundled two-source example with `bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/api_replay_eval.rb`. Then run `AGENT_REVISION=regressed bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/api_replay_eval.rb --fail-on-regression` to send deliberately wrong order arguments; strict replay records the mismatch and the regression gate exits nonzero.

Each declaration must be consumed **once, in declared order**. Declare a repeated call twice. Unexpected requests, parameter mismatches, exhausted fixtures, and missing calls produce an agent error even if the agent rescues the request exception or returns the expected answer. Query order is insignificant; repeated values and their multiplicity are preserved. `expect_request(json: { count: 1, enabled: false }, headers: { "X-Region" => "eu" })` asserts typed JSON and only declared headers (header names are case-insensitive). String `"1"` is not number `1`, and `null` is not `false`. Omitting request `json:` requires an empty body.

`respond_with` requires exactly one source: inline `json:` (including `json: nil` for JSON null), or `body_file: "fixtures/order.json"`. Files resolve relative to the spec file where the question was declared, not the process working directory. Missing files, invalid JSON, and invalid UTF-8 fail before agent execution. Exact file bytes, including whitespace and final newline, are snapshotted and returned unchanged. Optional `status:` defaults to 200; `headers:` defaults to an empty map.

Absolute `body_file:` paths are also accepted; prefer spec-relative paths for portable, shareable fixtures.

Replay is strict/offline by default: undeclared network requests fail. For live model requests made by the agent itself, explicitly use `api_interactions(allow_hosts: ["api.openai.com"]) do ... end`. Allowances match exact hosts, not suffixes or wildcards, and may incur provider charges. An allowed host never bypasses a declared fixture request. Judge calls need no replay allowance because judging runs outside replay. There is no recording mode.

PostgreSQL case results persist `response_metadata["api_replay"]` on success and failure: expected interactions, observed match statuses, readable mismatch differences, and missing requests. Authentication/credential fields are redacted from replay evidence. Still use synthetic fixtures: never commit credentials or sensitive payloads, and protect persisted prompts, answers, and reports.

Replay evidence uses the existing response-metadata display in reports and the dashboard; JSON reports include the persisted `response_metadata.api_replay` payload. No separate evidence store or migration is required.

Request assertions, response status/headers, allowed hosts, and response-byte hashes participate in suite fingerprints. Changing fixture bytes (even JSON whitespace) creates an incompatible baseline, not a regression against the old fixture. Existing definitions retain snapshotted bytes; reload/redefine the spec to adopt file changes. Suites without replay keep their existing fingerprints.

## Large tool-result evaluation

[examples/context_bloat_eval.rb](examples/context_bloat_eval.rb) replays a roughly 500 KB JSON API response with the relevant current policy after a long history. It evaluates three independent requirements: the correct answer, the expected tool name/arguments, and a maximum 4,096-byte model-facing tool result. The normal tool extracts the relevant facts; `AGENT_REVISION=regressed` sends the entire response. A correct answer does not excuse exceeding the declared tool-result budget. Actual API and tool-result byte counts are saved in response metadata.

This is a byte budget for tool output, not a tokenizer or a claim that the complete prompt fits every model window. The local integration test exercises actual RubyLLM HTTP/tool transport with scripted model responses; it does not prove model reasoning. Use the opt-in provider example to evaluate real model behavior. It requires your credentials and incurs charges; the external policy API remains replayed. A real provider context-limit failure is recorded as an agent error, never hidden.

~~~sh
# Requires DATABASE_URL, migrations, and your OPENAI_API_KEY.
RUN_CONTEXT_BLOAT_EVAL=1 OPENAI_MODEL=gpt-4.1-mini bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/context_bloat_eval.rb

# Intentionally expose oversized tool output; expect a failure or provider limit error.
RUN_CONTEXT_BLOAT_EVAL=1 AGENT_REVISION=regressed OPENAI_MODEL=gpt-4.1-mini bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/context_bloat_eval.rb --fail-on-regression
~~~

WebMock interception is process-global. Replay cases are serialized and restore caller state, but run evaluations in a dedicated process rather than alongside unrelated application HTTP traffic. Custom transports outside WebMock support are not intercepted.

## Optional judge agent in the suite constructor

Use a class inheriting from RubyLLM::Agent (RubyLLM 1.14.1+). The evaluation suite creates a fresh instance for each assessment and calls its ask method, so judge conversations do not leak between metrics or questions:

~~~ruby
require "ruby_llm"
require "ruby_llm/evaluations"

class SupportJudgeAgent < RubyLLM::Agent
  model ENV.fetch("EVAL_JUDGE_MODEL")
end

suite = RubyLLM::Evaluations::Suite.new(
  "Customer support", agent: support_agent, judge: SupportJudgeAgent
)
suite.question "How long do I have to return an item?", expected_answer: "30 days",
               minimum_scores: { semantic_accuracy: 0.9, answer_relevancy: 0.9 }
~~~

The define DSL forwards judge: to this same constructor. Provider credentials use your application's normal RubyLLM configuration; no separate evaluation-judge configuration is needed. Supplying a judge makes real model requests when the suite runs and can incur charges.

Omit judge: to skip semantic_accuracy, answer_relevancy, and custom llm_judge checks. Declared minimum_scores and agent outputs are still persisted. A question with no calculated metrics is not_evaluated, not passed; score and pass rate are null when no questions were evaluated. Mixed suites calculate quality only from executed metrics and evaluated questions. A different calculated metric set changes the fingerprint, so runs that skipped LLM metrics are never automatic regression baselines for runs that calculated them.

Judge replies must contain a finite numeric score in [0,1] and a nonempty string reason. Invalid replies and provider failures remain metric errors, never passing defaults. Model judgments are nondeterministic: calibrate thresholds against human-reviewed examples. Marking data untrusted does not eliminate prompt injection.

[examples/ruby_llm_eval.rb](examples/ruby_llm_eval.rb) supplies a RubyLLM judge agent class to the suite. [examples/semantic_actions_eval.rb](examples/semantic_actions_eval.rb) combines real agent/tool/judge calls and all three dimensions. Configure provider credentials and EVAL_MODEL/EVAL_JUDGE_MODEL before running these opt-in examples; neither runs automatically.

## Rails: named models and standard migrations

Add the gem to your application's Gemfile (use a local path during development):

~~~ruby
gem "ruby_llm-evaluations", path: "/path/to/ruby_llm-evaluations"
~~~

Install the engine migrations into the host application, then migrate normally:

~~~sh
bin/rails ruby_llm_evaluations:install:migrations
bin/rails db:migrate
~~~

When upgrading, repeat the install:migrations and db:migrate commands to install and apply new engine migrations; keep existing migrations and history. Standalone users instead run ruby_llm-evaluations db:migrate before their next run.

PostgreSQL is required. Tables are ruby_llm_evaluations_runs, ruby_llm_evaluations_case_results, and ruby_llm_evaluations_metric_results. Existing legacy payload history is migrated, not discarded. There are no Store objects, dynamically allocated models, or separate connection pools. Execution does not establish, migrate, or disconnect the host pool.

~~~ruby
# config/routes.rb
Rails.application.routes.draw do
  mount RubyLLM::Evaluations::Engine => "/evaluations"
end
~~~

Visit /evaluations. Assets, filters, detail/baseline links, and downloads respect the mount path. The dashboard has **no built-in authentication**: protect it with application authorization or a trusted reverse proxy before exposing sensitive data. It accepts GET/HEAD only.

## Offline quick start: exact match, not semantic judging

Requirements: Ruby 3.2+, PostgreSQL, Bundler. Rails and RubyLLM are optional. This deterministic local demo runs without API keys and is deliberately separate from semantic judging. It performs a real local answer lookup and records that action; exact match is not a semantic judge.

~~~sh
bundle install
docker compose up -d --wait
export DATABASE_URL='postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations'

# Migrate once before executing specs. Runs never create tables implicitly.
bundle exec ruby -Ilib exe/ruby_llm-evaluations db:migrate
bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/support_eval.rb --metadata '{"revision":"reference"}'

# Exit 1 is intentional: incorrect answer and wrong lookup arguments.
AGENT_REVISION=regressed bundle exec ruby -Ilib exe/ruby_llm-evaluations run examples/support_eval.rb --fail-on-regression --metadata '{"revision":"regressed"}'

bundle exec ruby -Ilib exe/ruby_llm-evaluations history
bundle exec ruby -Ilib exe/ruby_llm-evaluations dashboard
~~~

Open **http://127.0.0.1:4567**; Ctrl-C stops the server. PostgreSQL evidence survives restarts. Compose binds passwordless development PostgreSQL to loopback port 55432; **do not use this configuration in production**. Its named volume preserves history; docker compose stop does not delete it. For your own service, set DATABASE_URL to an existing database.

The offline example produces the following evidence:

| Revision | Passing questions | Quality score | CLI exit |
| --- | --- | --- | --- |
| Reference | 3 of 3 | 1.000 | 0 |
| Regressed | 2 of 3 | 0.667 | 1 |

The regressed agent answers the return question with 7 days instead of 30 and looks up shipping rather than returns. Both the answer check and observed-action check fail.

The standalone CLI alone establishes ActiveRecord::Base's connection. Standalone library callers configure it themselves:

~~~ruby
ActiveRecord::Base.establish_connection(ENV.fetch("DATABASE_URL"))
RubyLLM::Evaluations.migrate! # Once during database setup, not per run.
~~~

## Custom checks and action traces

Explicit suite-level evaluators remain available for custom scoring and become defaults for questions without minimum_scores:

~~~ruby
RubyLLM::Evaluations.define("Concise answers", agent: your_agent) do
  evaluate :conciseness, threshold: 0.8 do |output, context|
    score = output.split.size <= context.metadata.fetch(:max_words) ? 1.0 : 0.0
    RubyLLM::Evaluations::Assessment.new(score: score, reason: "Checked word budget")
  end
  question "Explain returns briefly", expected_answer: "Return within 30 days.",
           minimum_scores: { conciseness: 0.8 }, metadata: { max_words: 12 }
end
~~~

Evaluators receive (output, context). Context exposes id, name, question, expected_answer, expected_actions, minimum_scores, metadata, question_data, response, and the suite's judge agent class. Return Boolean, a finite score in [0,1], or an Assessment. Deterministic built-ins include exact_match, contains, matches(/pattern/), and valid_json; register them with evaluate(name, using:, threshold:). Evaluators.llm_judge(rubric:) supports custom rubrics and uses the constructor judge; without a judge it is skipped.

Select action_group in question minimum_scores and declare the expected invocation trace:

~~~ruby
question "Track order 42", expected_answer: "Order 42 has shipped.",
         minimum_scores: { action_group: 1.0 },
         expected_actions: [{ group: "orders", name: "lookup_order", arguments: { id: 42 } }]
~~~

The agent must return **observed**, not assumed, calls:

~~~ruby
RubyLLM::Evaluations::Response.new(
  output: "Order 42 has shipped.",
  actions: [{ group: "orders", name: "lookup_order", arguments: { id: 42 } }],
  input_tokens: 120, output_tokens: 18, cost: 0.0002,
  metadata: { model: "your-model" }
)
~~~

Group, name, arguments, and order must match exactly. Missing/incorrect/extra calls reduce the score. Expected actions require groups. actions: nil means missing instrumentation and produces an error; actions: [] honestly means observed no actions. A narrative promise is never evidence of execution.

The RubyLLM adapter captures calls with action_groups: { "lookup_order" => "orders" }; unknown groups remain nil, not invented. Its factory must return a fresh chat for each call. Plain RubyLLM messages normalize output/usage but do not contain preceding action traces. Generic callables are reused: create fresh state inside the callable when needed. Runner copies question data so agent mutation cannot alter the suite.

## Persisted evidence and compatible baselines

~~~ruby
run = RubyLLM::Evaluations.run(suite, metadata: { revision: "candidate" })
# An actual RubyLLM::Evaluations::Run ActiveRecord record.
report = RubyLLM::Evaluations::Report.new(run, baseline: run.previous, tolerance: 0.02)
report.export("agent-report.html")

RubyLLM::Evaluations::Run.recent.for_suite("Customer support").with_results
run.case_results.first.metric_results
snapshot = run.snapshot # Detached JSON-portable evidence, not a persistence API.
~~~

Report#export writes the file itself and returns its path. The extension chooses HTML (.html/.htm), JSON (.json), Markdown (.md/.markdown), or text (.txt/.text). Use report.export("agent-report", format: :html) when the filename has no recognized extension. Unknown formats fail before writing; file-system errors propagate. String-returning to_html/to_json/to_markdown/to_text remain available for in-memory use.

Run, CaseResult, and MetricResult records are readonly after persistence through normal ActiveRecord APIs. Runner finishes agent/judge calls before the short atomic save transaction; errors are recorded and other questions/checks continue. Runner.new.run(suite, metadata: {}) is also available.

Baselines are earlier runs matching suite, agent, and typed definition fingerprint, with database-generated sequence breaking timestamp ties. Fingerprints cover question data, expected answers/actions, metric names and thresholds in minimum_scores, metadata, and explicit suite version. Changing minimum_scores changes the definition fingerprint, so different threshold sets are not automatically compared. Renaming the API alone preserves existing definition fingerprints and baseline history. **Bump version when changing evaluator implementations, rubrics, or judge configuration**; callable source is not hashed. Keep agent identity stable across revisions and record revision/model/prompt information in run metadata.

A question passes only when at least one metric was calculated and every calculated metric passes without error. With no calculated metrics it is not_evaluated. Case quality averages calculated metric scores (metric errors contribute zero); agent errors yield zero. Run quality and pass rate exclude not-evaluated questions and are null when no questions were evaluated. Completed status means execution finished, not success. Token/cost totals include only reported agent usage, not judge usage; zero totals do not prove zero cost. Response costs are USD for dashboard display.

Regression comparison is separate from minimum-score passing: it compares later observed scores against a previous run of the same definition. Use --fail-on-regression to make regressions fail the CLI gate and --tolerance to allow small score decreases. Regressions include score decreases beyond tolerance, newly failed thresholds, and new errors. Tolerance does not hide new failures/errors. Missing/incompatible explicit baselines are rejected before agent execution; automatic historical baselines never come from the future.

For example, with a semantic-accuracy minimum of 0.9, a previous score of 0.98 and a later score of 0.92 both pass the minimum. The later run nevertheless regresses by 0.06 when tolerance is 0.02, so --fail-on-regression fails the gate. On the first run, the same minimum applies but there is no previous score to compare.

~~~sh
ruby_llm-evaluations run your_eval.rb --fail-on-regression --tolerance 0.02
ruby_llm-evaluations run your_eval.rb --baseline RUN_ID --fail-on-regression
ruby_llm-evaluations history --suite 'Customer support' --agent SupportAgent --limit 50
ruby_llm-evaluations report --format html --output agent.html
ruby_llm-evaluations report --format markdown --output agent.md
ruby_llm-evaluations report RUN_ID --baseline BASELINE_ID --format json
~~~

CLI exits: **0** no failed/errored calculated checks or regression gate, **1** failed/errored checks or detected gated regression, **2** invalid specification/options/configuration/baseline. Exit 0 does not claim quality when all checks were skipped; inspect not_evaluated and null scores. HTML reports escape output and need no external assets. JSON contains the top-level run snapshot plus comparison, with per-case metrics (not a run wrapper). The dashboard offers JSON downloads.

## Dashboard evidence

These current screenshots were captured from persisted offline PostgreSQL runs and generated reports. They show deterministic exact-match/action checks, real history, and regression evidence—not live model reasoning.

![Evaluation history and quality trends](docs/images/dashboard-history.png)
![Regression report](docs/images/dashboard-regression.png)
![Case answer and observed actions](docs/images/dashboard-case.png)
![Standalone HTML report](docs/images/html-report.png)
![Narrow dashboard](docs/images/dashboard-mobile.png)

With no judge supplied, the actual dashboard records answers but leaves quality unavailable and draws no invented trend. This capture uses RubyLLM against a local scripted HTTP provider, not live model reasoning:

![Persisted answers without a judge: unavailable quality and no fabricated scores](docs/images/dashboard-without-judge.png)

## Development and packaging

Integration tests always: behavior changes must update end-to-end coverage. PostgreSQL is required; integration tests must never silently skip.

~~~sh
docker compose exec -T postgres createdb -U postgres ruby_llm_evaluations_test
export TEST_DATABASE_URL='postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations_test'
bundle exec rake integration
bundle exec rake test

gem build ruby_llm-evaluations.gemspec
gem install ./ruby_llm-evaluations-0.1.0.gem
ruby_llm-evaluations --help
~~~

Tests isolate PostgreSQL schemas rather than clear development history; the test role needs schema-creation privileges. Local HTTP provider fixtures verify real adapter transport/orchestration, not model reasoning. Default tests never call paid providers. For UI changes inspect desktop/narrow layouts, keyboard access, filters, chart navigation, and downloads. Shared engineering guidance and specialist skills live in [.agents/](.agents/AGENTS.md).

## Data and security

Specs execute trusted code. Answers and judge data are untrusted. Prompts, references, traces, errors, and metadata persist in the database and exports: redact sensitive information and manage retention/backups. Never commit credentials or production data. No hosted backend, external dashboard assets, framework provider retries, or automatic-success fallbacks are supplied.

## License

MIT. See [LICENSE](LICENSE).
