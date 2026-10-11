# frozen_string_literal: true

require "minitest/autorun"
require_relative "postgres_helper"
require_relative "../lib/ruby_llm/evaluations"

class EvaluationTest < Minitest::Test
  E = RubyLLM::Evaluations

  def setup
    @sandbox = PostgresSandbox.new
    @store = E::Store.new(@sandbox.database_url)
  end

  def teardown
    @store.close
    @sandbox.close
  end

  def run_suite(agent:, &block)
    suite = E.define("checks", agent: agent, &block)
    E::Runner.new(store: @store).run(suite)
  end

  def test_agent_error_is_persisted_without_aborting_remaining_cases
    agent = ->(input) { raise "provider unavailable" if input == "bad"; input.upcase }
    run = run_suite(agent: agent) do
      evaluate :answer, using: E::Evaluators.exact_match
      test "provider error", input: "bad", expected: "BAD"
      test "success", input: "ok", expected: "OK"
    end
    assert_equal %w[error passed], run["cases"].map { |item| item["status"] }
    assert_equal({ "class" => "RuntimeError", "message" => "provider unavailable" }, run["cases"][0]["error"])
    assert_equal 0.5, run["summary"]["pass_rate"]
    assert_equal 0.5, run["summary"]["score"]
    assert_equal run, @store.find(run["id"])
  end

  def test_evaluator_error_does_not_skip_other_checks
    run = run_suite(agent: ->(input) { input }) do
      evaluate(:broken) { |_output, _test_case| raise "judge unavailable" }
      evaluate(:correct) { |output, test_case| E::Assessment.new(score: output == test_case.expected, reason: "matched") }
      test "answer", input: "yes", expected: "yes"
    end
    result = run["cases"].first
    assert_equal "error", result["status"]
    assert_equal "judge unavailable", result["evaluations"][0]["error"]["message"]
    assert_equal 1.0, result["evaluations"][1]["score"]
    assert_equal "matched", result["evaluations"][1]["reason"]
    assert_equal 0.5, run["summary"]["score"]
  end

  def test_threshold_is_inclusive_and_nonfinite_scores_become_errors
    run = run_suite(agent: ->(input) { input }) do
      evaluate(:quality, threshold: 0.75) { |output, _test_case| output }
      test "boundary", input: 0.75
      test "below", input: 0.749
    end
    assert_equal %w[passed failed], run["cases"].map { |item| item["status"] }
    bad = run_suite(agent: ->(_input) { "answer" }) do
      evaluate(:quality) { |_output, _test_case| Float::NAN }
      test "invalid score", input: "prompt"
    end
    assert_equal "error", bad["cases"].first["status"]
    assert_nil @store.find(bad["id"])["cases"].first["evaluations"].first["score"]
    assert_equal 0.0, bad["summary"]["score"]
  end

  def test_mutating_agent_input_does_not_change_the_dataset_or_later_runs
    input = { values: ["original"] }
    suite = E.define("mutable agent", agent: ->(data) { data[:values].first.replace("changed"); data[:values].first }) do
      evaluate :answer, using: E::Evaluators.exact_match
      test "mutation", input: input, expected: "changed"
    end
    before = suite.digest
    first = E::Runner.new(store: @store).run(suite)
    second = E::Runner.new(store: @store).run(suite)
    assert_equal "original", input[:values].first
    assert_equal before, second["suite_digest"]
    assert_equal({ "values" => ["original"] }, first["cases"].first["input"])
    assert_equal "passed", second["cases"].first["status"]
  end

  def test_digest_changes_with_dataset_threshold_and_explicit_evaluator_version
    build = lambda do |expected, threshold, version|
      E.define("stable suite", agent: ->(input) { input }, version: version) do
        evaluate :answer, using: E::Evaluators.exact_match, threshold: threshold
        test "case", input: "prompt", expected: expected
      end
    end
    base = build.call("answer", 1.0, "1").digest
    refute_equal base, build.call("other", 1.0, "1").digest
    refute_equal base, build.call("answer", 0.5, "1").digest
    refute_equal base, build.call("answer", 1.0, "2").digest
  end

  def test_response_usage_and_metadata_are_persisted
    agent = ->(_input) { E::Response.new(output: "ok", input_tokens: 12, output_tokens: 3, cost: 0.002, metadata: { model: "local" }) }
    run = run_suite(agent: agent) do
      evaluate :answer, using: E::Evaluators.exact_match
      test "usage", input: "prompt", expected: "ok"
    end
    result = @store.find(run["id"])
    assert_equal 12, result["summary"]["input_tokens"]
    assert_equal 3, result["summary"]["output_tokens"]
    assert_equal 0.002, result["summary"]["cost"]
    assert_equal({ "model" => "local" }, result["cases"].first["response_metadata"])
  end

  def test_digest_preserves_ruby_input_types_and_ignores_hash_insertion_order
    build = lambda do |input|
      E.define("typed inputs", agent: ->(value) { value }) do
        evaluate(:quality) { true }
        test "data", input: input
      end
    end
    refute_equal build.call({ prompt: "hello" }).digest, build.call({ "prompt" => "hello" }).digest
    refute_equal build.call(:hello).digest, build.call("hello").digest
    assert_equal build.call({ prompt: "hello", count: 2 }).digest, build.call({ count: 2, prompt: "hello" }).digest
  end

  def test_judge_output_is_scored_and_malformed_json_is_an_evaluator_error
    judge = ->(_prompt) { '{"score":0.8,"reason":"Factually correct"}' }
    evaluator = E::Evaluators.llm_judge(judge: judge, rubric: "Factual accuracy")
    run = run_suite(agent: ->(_input) { "Paris" }) do
      evaluate :judge, using: evaluator, threshold: 0.7
      test "capital", input: "France?", expected: "Paris"
    end
    assert_equal "passed", run["cases"].first["status"]
    assert_equal "Factually correct", run["cases"].first["evaluations"].first["reason"]
    invalid = E::Evaluators.llm_judge(judge: ->(_prompt) { "not JSON" }, rubric: "Accuracy")
    run = run_suite(agent: ->(_input) { "Paris" }) do
      evaluate :judge, using: invalid
      test "capital", input: "France?"
    end
    assert_equal "error", run["cases"].first["status"]
    assert_equal "JSON::ParserError", run["cases"].first["evaluations"].first["error"]["class"]
  end
end
