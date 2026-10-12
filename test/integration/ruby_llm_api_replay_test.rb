# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "ruby_llm"
require_relative "../../lib/ruby_llm/evaluations"
require_relative "../postgres_helper"
require_relative "../support/local_llm_server"

class RubyLLMAPIReplayTest < Minitest::Test
  E = RubyLLM::Evaluations

  class RemoteReturnPolicy < RubyLLM::Tool
    description "Read the return policy API"
    param :product, desc: "Product name"
    def name = "return_policy"

    def execute(product:)
      uri = URI("https://policy.example/returns")
      uri.query = URI.encode_www_form(product: product)
      Net::HTTP.get_response(uri).body
    end
  end

  def setup
    @sandbox = PostgresSandbox.new
    @server = LocalLLMServer.new
    config = RubyLLM::Configuration.new
    config.openai_api_key = "local-fixture-only"
    config.openai_api_base = @server.base_url
    config.max_retries = 0
    config.http_proxy = nil
    @context = RubyLLM::Context.new(config)
  end

  def teardown
    @server&.close
    @sandbox&.close
  end

  def suite
    context = @context
    agent = E::Adapters.ruby_llm_chat(action_groups: { return_policy: "returns" }) do
      context.chat(model: "fixture-agent", provider: :openai, assume_model_exists: true)
        .with_tools(RemoteReturnPolicy)
    end
    E.define("Replayed policy API", agent: agent) do
      evaluate :exact_match, using: E::Evaluators.exact_match
      question "Can I return my book?", expected_answer: LocalLLMServer::ANSWER,
               minimum_scores: { exact_match: 1.0, action_group: 1.0 },
               expected_actions: [{ group: "returns", name: "return_policy", arguments: { product: "book" } }] do
        api_interactions(allow_hosts: ["127.0.0.1"]) do
          expect_request(method: :get, url: "https://policy.example/returns", query: { product: "book" })
            .respond_with(json: { product: "book", return_days: 30 })
        end
      end
    end
  end

  def test_real_model_transport_and_real_tool_use_replayed_api_and_detect_wrong_arguments
    definition = suite
    baseline = E.run(definition)
    item = baseline.case_results.first
    assert_equal "passed", item.status
    assert_equal [{ "group" => "returns", "name" => "return_policy", "arguments" => { "product" => "book" } }], item.actions
    tool_message = @server.requests.last.fetch("messages").find { |message| message["role"] == "tool" }
    assert_equal({ "product" => "book", "return_days" => 30 }, JSON.parse(tool_message.fetch("content")))
    assert_equal "passed", item.response_metadata.fetch("api_replay").fetch("status")

    @server.revision = :wrong_arguments
    current = E.run(definition)
    persisted = E::Run.find(current.id)
    assert_equal "error", persisted.case_results.first.status
    assert_equal "RubyLLM::Evaluations::ApiReplay::Mismatch", persisted.case_results.first.error_details.fetch("class")
    assert E::Report.new(persisted, baseline: baseline).comparison.fetch("regressed")
  end
  def test_large_tool_result_fails_budget_even_when_the_answer_is_correct
    require_relative "../../examples/context_bloat_eval"
    options = { context: @context, model: "fixture-agent", allow_host: "127.0.0.1",
                expected_answer: LocalLLMServer::ANSWER }
    baseline = E.run(ContextBloatExample.suite(**options))
    safe = baseline.case_results.first
    assert_equal "passed", safe.status
    assert_operator safe.response_metadata.fetch("api_response_bytes"), :>, ContextBloatExample::MAX_TOOL_RESULT_BYTES
    sent = @server.requests.last.fetch("messages").find { |message| message["role"] == "tool" }
    assert_equal({ "product" => "book", "return_days" => 30 }, JSON.parse(sent.fetch("content")))
    assert_operator sent.fetch("content").bytesize, :<=, ContextBloatExample::MAX_TOOL_RESULT_BYTES

    current = E.run(ContextBloatExample.suite(**options, raw: true))
    bloated = E::Run.find(current.id).case_results.first
    assert_equal "failed", bloated.status
    assert_equal LocalLLMServer::ANSWER, bloated.output
    metrics = bloated.metric_results.to_h { |metric| [metric.name, metric] }
    assert metrics.fetch("exact_match").passed
    assert metrics.fetch("action_group").passed
    refute metrics.fetch("tool_result_budget").passed
    assert_equal 0.0, metrics.fetch("tool_result_budget").score
    assert_equal [safe.response_metadata.fetch("api_response_bytes")], bloated.response_metadata.fetch("tool_result_bytes")
    report = E::Report.new(current, baseline: baseline)
    assert_equal ["tool_result_budget"], report.comparison.fetch("regressions").map { |change| change.fetch("evaluator") }
  end
end
