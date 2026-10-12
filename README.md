# RubyLLM Agent Evaluations

[![Gem version](https://img.shields.io/gem/v/ruby_llm-agent-evaluations.svg)](https://rubygems.org/gems/ruby_llm-agent-evaluations)
[![Tests](https://github.com/luisgsilva950/ruby_llm-evaluations/actions/workflows/ci.yml/badge.svg)](https://github.com/luisgsilva950/ruby_llm-evaluations/actions/workflows/ci.yml)

**Evaluate agent behavior. Replay external APIs. Catch regressions before shipping a model, prompt, or tool change.**

- **Any callable agent.** Your application owns models, credentials, and orchestration; RubyLLM is optional.
- **Question-first scoring.** Semantic accuracy, relevancy, deterministic checks, and observed tool-call correctness.
- **Strict API replay.** Assert request parameters before returning inline or file-backed JSON.
- **Durable evidence.** SQLite, PostgreSQL, or MySQL 8.0+; compatible baselines, exportable reports, and a read-only dashboard.

[Quick start](#quick-start) · [Rails](#rails) · [Scoring](#scoring) · [API replay](#api-replay) · [Reports](#reports-and-dashboard) · [Examples](#examples)

## Quick start

Requires Ruby 3.2+, Bundler, and one database driver. **No Rails, PostgreSQL server, or API key required for this example.**

Add to your `Gemfile`:

```ruby
source "https://rubygems.org"
gem "ruby_llm-agent-evaluations", "~> 0.2.2", require: "ruby_llm/evaluations"
gem "sqlite3" # Or your application's pg/mysql2 driver.
```

Save as `support_eval.rb`. This offline lookup demonstrates the pipeline, not model reasoning:

```ruby
require "ruby_llm/evaluations"

E = RubyLLM::Evaluations
policy = { "How long do I have to return an item?" => ENV.fetch("RETURN_WINDOW", "30 days") }
agent = ->(question) { policy.fetch(question) }

E.define("Return policy", agent: agent, agent_name: "SupportAgent", version: "1") do
  evaluate :exact_match, using: E::Evaluators.exact_match
  question "How long do I have to return an item?",
           expected_answer: "30 days", minimum_scores: { exact_match: 1.0 }
end
```

```sh
bundle install
bundle exec ruby_llm-agent-evaluations db:migrate
bundle exec ruby_llm-agent-evaluations run support_eval.rb
RETURN_WINDOW='7 days' bundle exec ruby_llm-agent-evaluations run support_eval.rb --fail-on-regression
bundle exec ruby_llm-agent-evaluations history
bundle exec ruby_llm-agent-evaluations dashboard
```

The reference passes; the changed answer exits **1**. Open **http://127.0.0.1:4567** to inspect both runs. Without `DATABASE_URL`, history persists in `ruby_llm_evaluations.sqlite3` in the current directory. Migrate once during setup, never per run.

## Rails

Keep your application's existing database driver, configuration, and connection pool:

```sh
bin/rails ruby_llm_evaluations:install:migrations
bin/rails db:migrate
```

```ruby
# config/routes.rb
mount RubyLLM::Evaluations::Engine => "/evaluations"
```

The engine creates **three tables**: runs, case results, and metric results. It uses `jsonb` on PostgreSQL and `json` elsewhere; MySQL's `utf8mb4_0900_bin` collation preserves exact identifiers. Execution never reconfigures the host pool. Existing PostgreSQL history needs no reset; gem updates do not rewrite copied migrations.

Standalone library callers configure ActiveRecord themselves. The CLI selects its connection using `DATABASE_URL` or `--database-url`.

**No built-in dashboard authentication.** Protect the Rails mount with application authorization.

## Scoring

`expected_answer` is the reference; `minimum_scores` contains inclusive thresholds in **[0, 1]**, applied even on the first run. Semantic scores are not string-similarity percentages.

| Dimension | Checks |
| --- | --- |
| `semantic_accuracy` | Factual meaning, contradictions, and omissions against the reference. |
| `answer_relevancy` | Responsiveness to the request; an on-topic answer can still be wrong. |
| `action_group` | Observed group, tool name, arguments, and order—including unexpected calls. |

Pass `judge: YourJudgeAgent`, a `RubyLLM::Agent` subclass, to `define` or `Suite.new` for semantic metrics. Each assessment uses a fresh instance; your application configures the model and credentials. See the complete [RubyLLM example](examples/ruby_llm_eval.rb). Provider calls incur charges.

Without a judge, LLM metrics are skipped. **No calculated metrics means `not_evaluated` with null quality/pass rate—not a passing substitute.** Unspecified metrics default to semantic accuracy/relevancy at 0.9 unless explicit evaluators are registered. Agent/evaluator failures remain errors; other checks continue.

Custom evaluators receive `(output, context)` and return a Boolean, finite score, or `Assessment`. Context includes case data and the full response:

```ruby
# Inside a suite; give the question metadata: { max_words: 12 }.
evaluate(:conciseness, threshold: 1.0) do |output, context|
  output.split.size <= context.metadata.fetch(:max_words)
end
```

Built-ins include `exact_match`, `contains`, `matches`, and `valid_json`. Action checks require observed `Response.actions` or the RubyLLM adapter's `action_groups`: `nil` means missing instrumentation; `[]` means no observed calls. Never infer execution from an answer.

**Passing is not the same as avoiding regression.** A drop from 0.98 to 0.92 passes a 0.9 minimum but regresses beyond a 0.02 tolerance. Baselines match earlier suite/agent/definition fingerprints. Questions, references/actions, minimums, metadata, fixture bytes, and suite version affect compatibility. **Bump suite `version` when changing scoring code, rubrics, or judge configuration**; callable source is not hashed.

### Structured responses (unreleased)

Score UI/protocol payloads separately from text. Add this to an **existing tool class**:

```ruby
prepend RubyLLM::Evaluations::ResponseComponentTool

def response_component
  { protocol: "a2ui", version: "0.8" }
end
```

Marked tools keep their original return values and callbacks. During `Evaluations.run` or the RubyLLM chat adapter, results are captured in call order with protocol, declared version, tool name, arguments, and payload; explicit final-response components follow them. Evaluators read `context.response.components`; history and reports retain the evidence without new tables or migrations. Outside a run, use `Response.capture { agent.call(question) }`.

```ruby
# Build the check separately; expected_ui_messages is parsed JSON in question metadata.
ui_check = RubyLLM::Evaluations::Evaluators.response_components(protocol: "a2ui", version: "0.8") do |components, context|
  actual_messages = components.flat_map do |component|
    component.fetch("payload").lines.map { |line| JSON.parse(line) }
  end
  actual_messages == context.metadata.fetch(:expected_ui_messages)
end

# Inside your suite:
evaluate :a2ui, using: ui_check
```

The evaluator rejects missing components, an empty matching set, or a wrong declared version before your check runs. Your block validates the schema and application contract; the gem does **not** certify A2UI compliance or render supplied UI. Payloads preserve their original JSON-compatible shape; JSON/JSONL strings are not automatically parsed.

Other agents can return `Response.new(output: nil, components: [{ protocol: "a2ui", version: "0.8", payload: data }])`; text is optional. `nil` means unreported components, `[]` means explicitly none. Capture is synchronous and fiber-local; worker-thread/streaming agents must assemble components explicitly. `response_components` in response metadata is reserved for persistence. Put expected UI data in question metadata and bump suite `version` when validators change.

See the [complete offline A2UI 0.8 example](examples/a2ui_eval.rb): run it normally, then with `AGENT_REVISION=regressed` or `AGENT_REVISION=missing_ui`. Correct text still passes; incorrect/missing UI fails. This feature is available on the review branch, not the published 0.2.2 gem.

## API replay

Keep API data fixed while exercising the real HTTP client. Save as `shipping_eval.rb` and run with the same CLI:

```ruby
require "net/http"
require "json"
require "ruby_llm/evaluations"

E = RubyLLM::Evaluations
agent = ->(_question) do
  response = Net::HTTP.get_response(URI("https://shipping.example/orders?id=42"))
  JSON.parse(response.body).fetch("status")
end

E.define("Shipping", agent: agent, agent_name: "ShippingAgent") do
  evaluate :exact_match, using: E::Evaluators.exact_match
  question "Track order 42", expected_answer: "ready" do
    api_interactions do
      expect_request(method: :get, url: "https://shipping.example/orders", query: { id: "42" })
        .respond_with(json: { status: "ready" })
    end
  end
end
```

For large responses, replace `json:` with `body_file: "fixtures/order.json"`. Files resolve relative to the spec; exact bytes are snapshotted and fingerprinted. Invalid/missing files fail before execution. See [inline and file fixtures](examples/api_replay_eval.rb).

Requests must match method, URL, query, typed JSON body, and declared headers **once, in order**. Unexpected, wrong, missing, or exhausted requests fail the case—even if rescued by the agent. JSON `1`, `"1"`, `false`, and `null` stay distinct; omitting request `json:` requires an empty body.

Replay wraps agent execution, supports WebMock-compatible clients, and persists redacted mismatch evidence. Seed database tools separately; there is no recording mode. Explicit `allow_hosts: ["api.openai.com"]` permits live model traffic without bypassing fixtures. Judges run outside replay.

**Use a dedicated process:** WebMock interception is process-global, although replay cases serialize and restore caller state.

## Reports and dashboard

```sh
bundle exec ruby_llm-agent-evaluations run support_eval.rb --fail-on-regression --tolerance 0.02
bundle exec ruby_llm-agent-evaluations history --suite 'Return policy' --limit 50
bundle exec ruby_llm-agent-evaluations report --format html --output report.html
bundle exec ruby_llm-agent-evaluations report RUN_ID --baseline BASELINE_ID --format json
```

```ruby
run = RubyLLM::Evaluations.run(suite, metadata: { revision: "candidate" })
report = RubyLLM::Evaluations::Report.new(run, baseline: run.previous, tolerance: 0.02)
report.export("report.html") # Also .json, .md, or .txt; export writes the file.
```

Runs have immutable UUIDs and append-only model APIs. Baselines are chronological, never from the future. Invalid/incompatible explicit baselines fail before agent execution; tolerance never hides newly failed thresholds or errors.

CLI exits: **0** no failed checks/gated regression, **1** failed/errored checks or gated regression, **2** invalid input/configuration. Exit 0 does not establish quality when all metrics were skipped. JSON exports contain the run plus `comparison`; usage totals cover reported agent usage, not judge usage.

The dashboard exposes filters, scores, baseline comparisons, case evidence, and JSON downloads. HTML reports escape output and need no external assets. This capture shows persisted offline evaluations, not live model reasoning:

![Evaluation history, quality trends, and baseline changes](docs/images/dashboard-history.png)

<details>
<summary>More screenshots</summary>

![Regression detail](docs/images/dashboard-regression.png)
![Answers and observed actions](docs/images/dashboard-case.png)
![Standalone HTML report](docs/images/html-report.png)
![Mobile dashboard](docs/images/dashboard-mobile.png)
![Without a judge: unavailable quality, no invented scores](docs/images/dashboard-without-judge.png)

</details>

## Examples

| Example | Purpose | Provider calls |
| --- | --- | --- |
| [Offline support](examples/support_eval.rb) | Answers, actions, regression gating. | None |
| [API replay](examples/api_replay_eval.rb) | Inline/file fixtures and request arguments. | None |
| [RubyLLM judging](examples/ruby_llm_eval.rb) | Semantic accuracy and relevancy. | Paid; opt-in |
| [Semantic + actions](examples/semantic_actions_eval.rb) | Answer and tool correctness together. | Paid; opt-in |
| [Context bloat](examples/context_bloat_eval.rb) | ~500 KB fixture, tool arguments, 4,096-byte tool-result budget. | Paid; opt-in |

The bloat example measures **bytes**, not tokens or universal context-window fit. Scripted-provider tests prove transport, not model reasoning. Bundled RubyLLM adapters/judges target **1.x (1.14.1+)**; 2.x adapter compatibility is not claimed. Generic callables do not require RubyLLM.

## Safety

Specs execute trusted Ruby. Evaluation data persists: use synthetic fixtures, redact sensitive information, and manage retention/backups. Never commit credentials, production data, databases, or sensitive reports. Judges are nondeterministic; calibrate against human review. Prompt injection remains a risk. The standalone dashboard is loopback-bound and GET/HEAD-only by default.

<details>
<summary>Development and publishing</summary>

Install native client headers required by `pg`/`mysql2`, then from this checkout:

```sh
bundle install
docker compose up -d --wait postgres mysql
# Once, if the test database does not exist:
docker compose exec -T postgres createdb -U postgres ruby_llm_evaluations_test
export TEST_DATABASE_URL='postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations_test'
export TEST_MYSQL_DATABASE_URL='mysql2://root:dev-only@127.0.0.1:53306/mysql'
bundle exec rake integration
bundle exec rake test
```

Tests isolate SQLite files, PostgreSQL schemas, and MySQL databases; test accounts need creation privileges. Default tests never call paid providers. Consumers need only their chosen driver. Compose credentials are **development-only**, bound to loopback. See [engineering guidance](.agents/AGENTS.md).

To publish, bump `lib/ruby_llm/evaluations/version.rb`, update [CHANGELOG](CHANGELOG.md), then:

```sh
bundle exec ruby script/publish --dry-run
gem signin
# Commit release changes before uploading.
bundle exec ruby script/publish
```

The script gates upload on tests, package checks, and installed-gem replay/persistence smoke. Dry runs upload nothing. Publication requires a clean committed tree and push-authorized RubyGems credentials (`GEM_HOST_API_KEY` supported); MFA may apply. Versions cannot be replaced. Git commits/tags/pushes are not automatic.

</details>

[MIT license](LICENSE) · [Changelog](CHANGELOG.md) · [RubyGems](https://rubygems.org/gems/ruby_llm-agent-evaluations)
