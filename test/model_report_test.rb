# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "nokogiri"
require_relative "postgres_helper"
require_relative "../lib/ruby_llm/evaluations"

class ModelReportTest < Minitest::Test
  E = RubyLLM::Evaluations
  def setup = @sandbox = PostgresSandbox.new
  def teardown = @sandbox.close

  def run_record(id: SecureRandom.uuid, started_at: "2026-01-01T00:00:00Z", suite: "Answers", agent: "Assistant", digest: "digest", score: 1.0, passed: true)
    attributes = { id: id, suite: suite, agent: agent, version: "1", suite_digest: digest,
      started_at: started_at, finished_at: started_at, status: "completed", metadata: { revision: id },
      summary: { cases: 1, passed: passed ? 1 : 0, failed: passed ? 0 : 1, errors: 0,
        pass_rate: passed ? 1.0 : 0.0, score: score, duration_ms: 12.5, input_tokens: 2, output_tokens: 3, cost: 0.004 },
      case_results_attributes: [{ case_id: "answer", name: "Answers accurately", position: 0,
        question: { prompt: "What is two plus two?" }, expected_answer: "4", minimum_scores: { accuracy: 0.8 }, metadata: {}, output: "4",
        status: passed ? "passed" : "failed", duration_ms: 12.5, input_tokens: 2, output_tokens: 3, cost: 0.004,
        metric_results_attributes: [{ name: "accuracy", position: 0, score: score, threshold: 0.8, passed: passed, reason: "Checked answer" }] }] }
    yield attributes if block_given?
    E::Run.create!(attributes)
  end

  def test_detached_snapshots_and_readonly_models
    run = run_record(id: "run-1")
    copy = run.snapshot
    copy["cases"][0]["output"] = "changed"
    assert_equal "4", E::Run.find(run.id).snapshot["cases"][0]["output"]
    [run, run.case_results.first, run.case_results.first.metric_results.first].each do |record|
      assert record.readonly?
      assert_raises(ActiveRecord::ReadOnlyRecord) { record.update!(record.attributes.except("id")) }
      assert_raises(ActiveRecord::ReadOnlyRecord, ActiveRecord::DeleteRestrictionError) { record.destroy! }
    end
    assert_equal [1, 1, 1], [E::Run.count, E::CaseResult.count, E::MetricResult.count]
    assert_raises(ActiveRecord::RecordNotUnique) { run_record(id: "run-1") }
  end

  def test_invalid_nested_graph_rolls_back_every_record
    assert_raises(ActiveRecord::RecordInvalid) do
      run_record { |attrs| attrs[:case_results_attributes][0][:metric_results_attributes][0][:threshold] = 2 }
    end
    assert_equal [0, 0, 0], [E::Run.count, E::CaseResult.count, E::MetricResult.count]
  end

  def test_scopes_chronology_and_same_timestamp_sequence
    future = run_record(id: "future", started_at: "2026-01-03T00:00:00Z")
    old = run_record(id: "old")
    run_record(id: "changed", digest: "changed")
    current = run_record(id: "current", started_at: "2026-01-02T00:00:00Z")
    assert_equal old.id, current.previous.id
    assert_nil old.previous
    assert_equal future.id, E::Run.recent.first.id
    assert_empty E::Run.for_suite("' OR 1 = 1 --")
    assert_equal 4, E::Run.for_suite("Answers").for_agent("Assistant").count
    second = run_record(id: "second")
    assert_equal old.id, second.previous.id
  end

  def test_report_compatibility_and_tolerance
    baseline = run_record(score: 0.9)
    current = run_record(score: 0.85)
    refute E::Report.new(current, baseline: baseline, tolerance: 0.1).comparison["regressed"]
    comparison = E::Report.new(current, baseline: baseline, tolerance: 0.01).comparison
    assert comparison["regressed"]
    assert_in_delta(-0.05, comparison["score_delta"])
    failed = run_record(score: 0.79, passed: false)
    assert E::Report.new(failed, baseline: baseline, tolerance: 1).comparison["regressed"]
    [run_record(suite: "Other"), run_record(agent: "Other"), run_record(digest: "Other")].each do |other|
      assert_raises(ArgumentError) { E::Report.new(current, baseline: other) }
    end
    [-0.1, Float::NAN].each { |tolerance| assert_raises(ArgumentError) { E::Report.new(current, tolerance: tolerance) } }
  end

  def test_new_metric_error_and_agent_error_are_regressions_and_recoveries
    baseline = run_record(score: 0, passed: false)
    current = run_record(score: 0, passed: false) do |attrs|
      item = attrs[:case_results_attributes][0]
      item[:status] = "error"
      item[:metric_results_attributes][0].merge!(score: nil, error_details: { class: "RuntimeError", message: "judge unavailable" })
    end
    assert E::Report.new(current, baseline: baseline, tolerance: 1).comparison["regressed"]
    recovered = run_record(score: 0, passed: false)
    assert_equal 1, E::Report.new(recovered, baseline: current).comparison["improvements"].size
    assert_raises(ArgumentError) { E::Report.new(baseline, baseline: current) }
    agent_error = run_record(score: 0, passed: false) do |attrs|
      attrs[:case_results_attributes][0].merge!(status: "error", error_details: { class: "Timeout::Error", message: "timed out" }, metric_results_attributes: [])
    end
    comparison = E::Report.new(agent_error, baseline: baseline).comparison
    assert_equal 1, comparison["regressions"].size
  end

  def test_formats_telemetry_top_level_json_and_untrusted_content
    baseline = run_record(score: 0.7, passed: false)
    attack = '<script>alert("bad")</script>&'
    current = run_record do |attrs|
      attrs[:case_results_attributes][0][:output] = attack
      attrs[:case_results_attributes][0][:metric_results_attributes][0][:reason] = "checked calculation"
    end
    report = E::Report.new(current, baseline: baseline)
    serialized = JSON.parse(report.to_json)
    assert_equal current.snapshot, serialized.reject { |key, _| key == "comparison" }
    assert_equal report.comparison, serialized["comparison"]
    refute_includes report.to_html, "<script>"
    assert_includes report.to_html, "&lt;script&gt;"
  end

  def test_export_writes_parseable_evidence_and_rejects_unsupported_formats_before_overwriting
    run = run_record
    report = E::Report.new(run)
    Dir.mktmpdir("report-export") do |directory|
      path = File.join(directory, "agent.json")
      assert_equal path, report.export(path)
      data = JSON.parse(File.read(path))
      assert_equal run.id, data.fetch("id")
      assert_equal "4", data.fetch("cases").first.fetch("expected_answer")
      assert_equal 1.0, data.fetch("cases").first.fetch("metrics").first.fetch("score")
      assert_raises(ArgumentError) { report.export(path, format: :unknown) }
      assert_equal data, JSON.parse(File.read(path))
      html = File.join(directory, "agent")
      report.export(html, format: :html)
      assert_equal run.id, Nokogiri::HTML(File.read(html)).at_css("section dd").text
    end
  end
end
