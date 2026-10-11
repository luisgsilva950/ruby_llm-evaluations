# frozen_string_literal: true
require "minitest/autorun"
require_relative "../postgres_helper"
require_relative "../../lib/ruby_llm/evaluations"

class MinimumScoresTest < Minitest::Test
  E = RubyLLM::Evaluations
  def setup = @sandbox = PostgresSandbox.new
  def teardown = @sandbox.close

  def suite(answer:, minimum: 0.9)
    E.define("Answer boundaries", agent: ->(_) { answer }, agent_name: "SupportAgent") do
      evaluate(:quality) { |output| { "complete" => 0.98, "adequate" => 0.92, "boundary" => 0.9, "weak" => 0.89 }.fetch(output) }
      question "What is the return deadline?", expected_answer: "30 days", minimum_scores: { quality: minimum }
    end
  end

  def test_first_run_uses_an_inclusive_absolute_minimum_without_a_baseline
    boundary = E.run(suite(answer: "boundary"))
    assert_nil boundary.previous
    assert_nil E::Report.new(boundary).comparison
    assert_equal "passed", boundary.case_results.first.status
    assert_equal 0.9, boundary.case_results.first.metric_results.first.threshold
    assert_equal 0.9, boundary.case_results.first.metric_results.first.score
    assert_equal({ "quality" => 0.9 }, boundary.case_results.first.minimum_scores)

    different_definition = suite(answer: "weak", minimum: 0.895)
    first_weak = E.run(different_definition)
    assert_nil first_weak.previous
    assert_equal "failed", first_weak.case_results.first.status
    assert_equal 0.89, first_weak.case_results.first.metric_results.first.score
  end

  def test_passing_its_minimum_does_not_hide_a_regression_against_previous_scores
    baseline = E.run(suite(answer: "complete"))
    current = E.run(suite(answer: "adequate"))
    assert_equal baseline.id, current.previous.id
    assert_equal "passed", current.case_results.first.status
    metric = current.case_results.first.metric_results.first
    assert metric.passed
    assert_equal 0.9, metric.threshold
    assert_equal 0.92, metric.score
    report = E::Report.new(current, baseline: current.previous, tolerance: 0.02)
    assert report.comparison["regressed"]
    assert_in_delta(-0.06, report.comparison["score_delta"], 1e-12)
    assert_equal "quality", report.comparison["regressions"].first["evaluator"]
    refute E::Report.new(current, baseline: baseline, tolerance: 0.07).comparison["regressed"]
  end
end
