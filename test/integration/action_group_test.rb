# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/ruby_llm/evaluations"
require_relative "../postgres_helper"

class ActionGroupIntegrationTest < Minitest::Test
  E = RubyLLM::Evaluations

  def setup
    @sandbox = PostgresSandbox.new

  end

  def teardown

    @sandbox.close
  end

  def action(name, arguments = {})
    { group: "orders", name: name, arguments: arguments }
  end

  def run_actions(actual, expected)
    suite = E.define("order actions", agent: ->(_input) { E::Response.new(output: "Your order is ready.", actions: actual) }) do
      evaluate :action_group, using: E::Evaluators.action_group
      question "Track order 42", expected_actions: expected, name: "check order"
    end
    E::Runner.new.run(suite).snapshot
  end

  def test_group_arguments_sequence_and_unexpected_calls_are_quality_evidence
    lookup = action("lookup", { id: 42 })
    status = action("status", { id: 42 })
    correct = run_actions([lookup, status], [lookup, status])
    assert_equal "passed", correct["cases"][0]["status"]
    [
      [[lookup], 0.5],
      [[status, lookup], 0.0],
      [[action("lookup", { id: 99 }), status], 0.5],
      [[lookup.merge(group: "billing"), status], 0.5],
      [[lookup, status, action("cancel", { id: 42 })], 2.0 / 3]
    ].each do |trace, expected_score|
      run = run_actions(trace, [lookup, status])
      persisted = E::Run.find(run["id"]).snapshot
      assert_equal "failed", persisted["cases"][0]["status"]
      assert_in_delta expected_score, persisted["cases"][0]["metrics"][0]["score"], 1e-12
      comparison = E::Report.new(E::Run.find(run["id"]), baseline: E::Run.find(correct["id"])).comparison
      assert_equal true, comparison["regressed"]
      assert_equal "action_group", comparison["regressions"][0]["evaluator"]
    end
  end

  def test_missing_instrumentation_is_not_an_empty_trace
    observed_empty = run_actions([], [])
    missing = run_actions(nil, [])
    assert_equal "passed", observed_empty["cases"][0]["status"]
    assert_equal [], E::Run.find(observed_empty["id"]).snapshot["cases"][0]["actions"]
    assert_equal "error", missing["cases"][0]["status"]
    assert_nil E::Run.find(missing["id"]).snapshot["cases"][0]["actions"]
    assert_includes missing["cases"][0]["metrics"][0]["error"]["message"], "action trace missing"
    assert E::Report.new(E::Run.find(missing["id"]), baseline: E::Run.find(observed_empty["id"])).comparison["regressed"]
  end

  def test_unrequested_actions_fail_even_with_a_correct_answer
    run = run_actions([action("cancel", { id: 42 })], [])
    assert_equal "Your order is ready.", run["cases"][0]["output"]
    assert_equal "failed", run["cases"][0]["status"]
    assert_equal 0.0, run["summary"]["score"]
  end
end
