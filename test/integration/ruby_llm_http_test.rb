# frozen_string_literal: true

require "minitest/autorun"
require "ruby_llm"
require_relative "../../lib/ruby_llm/evaluations"
require_relative "../postgres_helper"
require_relative "../support/local_llm_server"

class RubyLLMHTTPTest < Minitest::Test
  E = RubyLLM::Evaluations

  class ReturnPolicy < RubyLLM::Tool
    description "Read the local product return policy"
    param :product, desc: "Product name"
    def name = "return_policy"
    def execute(product:)
      JSON.generate(product: product, return_days: { "book" => 30, "pen" => 14 }.fetch(product))
    end
  end

  class StoreHours < RubyLLM::Tool
    description "Read local store opening hours"
    def name = "store_hours"
    def execute = JSON.generate(opens: "09:00", closes: "17:00")
  end

  def setup
    @global_config = RubyLLM.config
    @global_values = RubyLLM::Configuration.options.to_h { |key| [key, @global_config.public_send(key)] }
    @sandbox = PostgresSandbox.new
    @server = LocalLLMServer.new
    config = RubyLLM::Configuration.new
    config.openai_api_key = "local-fixture-only"
    config.openai_api_base = @server.base_url
    config.request_timeout = 5
    config.max_retries = 0
    config.http_proxy = nil
    @context = RubyLLM::Context.new(config)
    @chats = []
    @agent = E::Adapters.ruby_llm_chat(action_groups: { return_policy: "returns", store_hours: "hours" }) do
      chat = @context.chat(model: "fixture-agent", provider: :openai, assume_model_exists: true)
        .with_tools(ReturnPolicy, StoreHours)
      @chats << chat
      chat
    end
    @judge = E::Adapters.ruby_llm_chat do
      @context.chat(model: "fixture-judge", provider: :openai, assume_model_exists: true)
    end

  end

  def teardown

  ensure
    begin
      @server&.close
    ensure
      @sandbox&.close
    end
    assert_same @global_config, RubyLLM.config
    assert_equal @global_values, RubyLLM::Configuration.options.to_h { |key| [key, RubyLLM.config.public_send(key)] } if @global_values
  end

  def suite(inputs = ["Can I return my book?", "What is the return window for a book?"])
    agent = @agent
    judge = @judge
    E.define("HTTP return policy", agent: agent, agent_name: "local-support", version: "1") do
      evaluate :accuracy, using: E::Evaluators.semantic_accuracy(judge: judge), threshold: 0.9
      evaluate :relevance, using: E::Evaluators.answer_relevancy(judge: judge)
      evaluate :actions, using: E::Evaluators.action_group
      inputs.each_with_index do |input, index|
        question input, expected_answer: "Books can be returned within 30 days.", name: "return #{index}",
          expected_actions: [{ group: "returns", name: "return_policy", arguments: { product: "book" } }]
      end
    end
  end

  def assessment(item, name)
    item.fetch("metrics").find { |evaluation| evaluation.fetch("name") == name }
  end

  def test_http_tools_judges_usage_isolation_and_durable_action_regressions
    definition = suite
    baseline = E::Runner.new.run(definition).snapshot
    assert_equal %w[passed passed], baseline.fetch("cases").map { |item| item.fetch("status") }
    assert_in_delta 0.9833333333, baseline.fetch("summary").fetch("score"), 0.000001
    baseline.fetch("cases").each do |item|
      assert_equal LocalLLMServer::ANSWER, item.fetch("output")
      refute_equal item.fetch("expected_answer"), item.fetch("output")
      assert_equal item.fetch("expected_actions"), item.fetch("actions")
      assert_equal 30, item.fetch("input_tokens")
      assert_equal 7, item.fetch("output_tokens")
      assert_equal 0.95, assessment(item, "accuracy").fetch("score")
      assert_equal "Directly addresses the return request.", assessment(item, "relevance").fetch("reason")
    end
    assert_equal 60, baseline.fetch("summary").fetch("input_tokens")
    assert_equal [4, 4], @chats.map { |chat| chat.messages.size }
    refute_same @chats[0], @chats[1]
    assert @chats.all? { |chat| chat.messages.all? { |message| message.is_a?(RubyLLM::Message) } }
    starts = @server.requests.select { |request| request["model"] == "fixture-agent" && request["messages"].last["role"] == "user" }
    assert_equal definition.cases.map(&:question), starts.map { |request| request["messages"].fetch(0).fetch("content") }
    assert starts.all? { |request| request["messages"].size == 1 }
    continuations = @server.requests.select { |request| request["model"] == "fixture-agent" && request["messages"].last["role"] == "tool" }
    continuations.each do |request|
      result = JSON.parse(request["messages"].last.fetch("content"))
      assert_equal({ "product" => "book", "return_days" => 30 }, result)
      assert_equal "lookup", request["messages"].last.fetch("tool_call_id")
    end
    judges = @server.requests.select { |request| request["model"] == "fixture-judge" }
    assert_equal 4, judges.size
    assert judges.all? { |request| request["messages"].size == 1 }
    assert_equal 2, judges.count { |request| request["messages"].last["content"].include?("Score factual semantic agreement") }
    assert_equal 2, judges.count { |request| request["messages"].last["content"].include?("Judge relevancy independently of factual accuracy") }
    judges.each do |request|
      data = JSON.parse(request["messages"].last.fetch("content").lines.last)
      assert_equal LocalLLMServer::ANSWER, data.fetch("output")
      assert_equal "Books can be returned within 30 days.", data.fetch("expected_answer")
    end


    assert_equal baseline, E::Run.find(baseline.fetch("id")).snapshot
    [:wrong_arguments, :extra_action].each do |revision|
      @server.revision = revision
      run = E::Runner.new.run(definition).snapshot
      previous = E::Run.find(run.fetch("id")).previous.snapshot
      assert_equal baseline.fetch("id"), previous.fetch("id") if revision == :wrong_arguments
      run.fetch("cases").each do |item|
        assert_equal "failed", item.fetch("status")
        assert_equal LocalLLMServer::ANSWER, item.fetch("output")
        assert assessment(item, "accuracy").fetch("passed")
        assert assessment(item, "relevance").fetch("passed")
        assert_equal(revision == :wrong_arguments ? 0.0 : 0.5, assessment(item, "actions").fetch("score"))
        if revision == :wrong_arguments
          assert_equal "pen", item.fetch("actions").first.fetch("arguments").fetch("product")
        else
          assert_equal %w[returns hours], item.fetch("actions").map { |action| action.fetch("group") }
        end
      end
      report = E::Report.new(E::Run.find(run.fetch("id")), baseline: E::Run.find(baseline.fetch("id")))
      assert report.comparison.fetch("regressed")
      assert_equal ["actions"], report.comparison.fetch("regressions").map { |change| change.fetch("evaluator") }.uniq
      assert_operator report.comparison.fetch("score_delta"), :<, 0
      assert_includes report.to_text, "return_policy"
      assert_includes report.to_html, "return_policy"
      assert_includes report.to_markdown, "return_policy"
      assert_equal run.fetch("cases"), JSON.parse(report.to_json).fetch("cases")
      assert_equal run, E::Run.find(run.fetch("id")).snapshot
    end
  end

  def test_http_judge_errors_preserve_action_checks_and_later_cases
    @server.judge_failures = [:malformed, nil, :provider, nil, nil, nil]
    run = E::Runner.new.run(suite(["First book return?", "Second book return?", "Third book return?"])).snapshot
    assert_equal %w[error error passed], run.fetch("cases").map { |item| item.fetch("status") }
    assert_equal 2, run.fetch("summary").fetch("errors")
    first, second, last = run.fetch("cases")
    assert_equal "JSON::ParserError", assessment(first, "accuracy").fetch("error").fetch("class")
    assert_includes assessment(second, "accuracy").fetch("error").fetch("message"), "fixture judge unavailable"
    [first, second].each do |item|
      assert_nil assessment(item, "accuracy").fetch("score")
      refute assessment(item, "accuracy").fetch("passed")
      assert assessment(item, "relevance").fetch("passed")
      assert assessment(item, "actions").fetch("passed")
      assert_nil item.fetch("error")
      assert_equal LocalLLMServer::ANSWER, item.fetch("output")
    end
    assert assessment(last, "accuracy").fetch("passed")
    assert_equal 6, @server.requests.count { |request| request["model"] == "fixture-judge" }


    assert_equal run, E::Run.find(run.fetch("id")).snapshot
    report = E::Report.new(E::Run.find(run.fetch("id")))
    assert_includes report.to_text, "fixture judge unavailable"
    assert_includes report.to_html, "JSON::ParserError"
  end
  # Scripted HTTP judgments prove the real provider protocol, not model reasoning.
  def test_question_criteria_select_metrics_thresholds_and_transport_important_facts
    agent, judge = @agent, @judge
    definition = E.define("question metrics", agent: agent, judge: judge) do
      evaluate(:custom) { |_output, context| context.metadata[:important_facts].include?("Books have a 30-day deadline.") }
      question "Book return?", expected_answer: "30 days", criteria: { semantic_accuracy: 0.96, custom: 1 },
        metadata: { important_facts: ["Books have a 30-day deadline."] }
      question "Another book return?", expected_answer: "30 days", criteria: { answer_relevancy: 0.8 },
        metadata: { important_facts: ["Books have a 30-day deadline."] }
    end
    run = E.run(definition)
    first, second = run.snapshot["cases"]
    assert_equal %w[semantic_accuracy custom], first["metrics"].map { |metric| metric["name"] }
    assert_equal [0.96, 1.0], first["metrics"].map { |metric| metric["threshold"] }
    assert_equal "failed", first["status"]
    assert_equal ["answer_relevancy"], second["metrics"].map { |metric| metric["name"] }
    assert_equal "passed", second["status"]
    requests = @server.requests.select { |request| request["model"] == "fixture-judge" }
    assert_equal 2, requests.size
    requests.each do |request|
      data = JSON.parse(request["messages"].last["content"].lines.last)
      assert_equal ["Books have a 30-day deadline."], data.fetch("metadata").fetch("important_facts")
      assert_equal "30 days", data.fetch("expected_answer")
      assert data.key?("question")
    end
  end

end
