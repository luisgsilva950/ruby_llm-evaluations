# frozen_string_literal: true

require "minitest/autorun"
require_relative "postgres_helper"
require_relative "../lib/ruby_llm/evaluations"

class StoreReportTest < Minitest::Test
  Store = RubyLLM::Evaluations::Store
  Report = RubyLLM::Evaluations::Report

  def setup
    @sandbox = PostgresSandbox.new
    @path = @sandbox.database_url
    @store = Store.new(@path)
  end

  def teardown
    @store.close
    @sandbox.close
  end

  def run_record(id: "run-1", started_at: "2026-01-01T00:00:00Z", suite: "Answers", agent: "Assistant", digest: "digest", score: 1.0, passed: true)
    {
      "id" => id, "suite" => suite, "agent" => agent, "suite_digest" => digest,
      "started_at" => started_at, "finished_at" => started_at, "status" => "completed", "metadata" => { "revision" => id },
      "summary" => {
        "cases" => 1, "passed" => passed ? 1 : 0, "failed" => passed ? 0 : 1, "errors" => 0,
        "pass_rate" => passed ? 1.0 : 0.0, "score" => score, "duration_ms" => 12.5,
        "input_tokens" => 2, "output_tokens" => 3, "cost" => 0.004
      },
      "cases" => [{
        "id" => "answer", "name" => "Answers accurately", "input" => { "prompt" => "What is two plus two?" },
        "expected" => "4", "metadata" => {}, "output" => "4", "status" => passed ? "passed" : "failed",
        "duration_ms" => 12.5, "input_tokens" => 2, "output_tokens" => 3, "cost" => 0.004, "error" => nil,
        "evaluations" => [{ "name" => "accuracy", "score" => score, "threshold" => 0.8, "passed" => passed, "reason" => "Checked answer", "error" => nil }]
      }]
    }
  end

  def test_persistence_across_reopen_and_detached_values
    original = run_record
    assert_equal original, @store.save(original)
    original["cases"][0]["output"] = "changed"
    @store.close
    @store = Store.new(@path)
    stored = @store.find("run-1")
    assert_equal "4", stored["cases"][0]["output"]
    stored["cases"][0]["output"] = "also changed"
    assert_equal "4", @store.find("run-1")["cases"][0]["output"]
  end

  def test_duplicate_identifier_cannot_overwrite_a_run
    @store.save(run_record)
    replacement = run_record(score: 0.2, passed: false)
    assert_raises(RubyLLM::Evaluations::Error) { @store.save(replacement) }
    assert_equal 1.0, @store.find("run-1").fetch("summary").fetch("score")
    @store.save(run_record(id: "next"))
    assert_equal 2, @store.list.length
  end

  def test_history_filters_limits_and_chronological_not_insertion_order
    @store.save(run_record(id: "new", started_at: "2026-01-03T00:00:00Z"))
    @store.save(run_record(id: "old", started_at: "2026-01-01T01:00:00+01:00"))
    @store.save(run_record(id: "other-suite", suite: "Other", started_at: "2026-01-04T00:00:00Z"))
    @store.save(run_record(id: "other-agent", agent: "Other", started_at: "2026-01-02T00:00:00Z"))
    assert_equal %w[other-suite new other-agent old], @store.list.map { |item| item["id"] }
    assert_equal %w[new old], @store.list(suite: "Answers", agent: "Assistant").map { |item| item["id"] }
    assert_equal ["other-suite"], @store.list(limit: 1).map { |item| item["id"] }
    assert_equal [], @store.list(limit: 0)
    assert_equal [], @store.list(suite: "' OR 1 = 1 --")
    assert_raises(ArgumentError) { @store.list(limit: -1) }
  end

  def test_missing_runs_and_baselines
    assert_nil @store.find("absent")
    assert_nil @store.latest(suite: "Answers", agent: "Assistant", suite_digest: "digest")
    @store.save(run_record)
    assert_nil @store.latest(suite: "Answers", agent: "Assistant", suite_digest: "digest", before_id: "absent")
  end

  def test_historical_baseline_excludes_future_runs_and_other_datasets
    @store.save(run_record(id: "future", started_at: "2026-01-03T00:00:00Z"))
    @store.save(run_record(id: "old", started_at: "2026-01-01T00:00:00Z"))
    @store.save(run_record(id: "changed", digest: "changed", started_at: "2026-01-01T12:00:00Z"))
    @store.save(run_record(id: "current", started_at: "2026-01-02T00:00:00Z"))
    arguments = { suite: "Answers", agent: "Assistant", suite_digest: "digest" }
    assert_equal "future", @store.latest(**arguments)["id"]
    assert_equal "old", @store.latest(**arguments, before_id: "current")["id"]
    assert_nil @store.latest(**arguments, before_id: "old")
  end

  def test_equal_timestamps_have_deterministic_previous_baselines
    %w[first second third].each { |id| @store.save(run_record(id: id)) }
    arguments = { suite: "Answers", agent: "Assistant", suite_digest: "digest" }
    assert_equal %w[third second first], @store.list.map { |item| item["id"] }
    assert_equal "first", @store.latest(**arguments, before_id: "second")["id"]
  end

  def test_shared_store_is_thread_safe
    threads = 8.times.map do |index|
      Thread.new do
        record = run_record(id: "thread-#{index}")
        @store.save(record)
        raise "missing thread result" unless @store.find(record["id"]) == record
      end
    end
    threads.each(&:value)
    assert_equal 8, @store.list.length
    @store.close
    @store.close
    assert_raises(RubyLLM::Evaluations::Error) { @store.list }
  end

  def test_future_schema_is_not_silently_overwritten
    @store.close
    peer = Store.new(@path)
    peer.instance_variable_get(:@model).connection_pool.with_connection do |database|
      database.execute("UPDATE ruby_llm_evaluations_schema_versions SET version = 99")
    end
    peer.close
    assert_raises(RubyLLM::Evaluations::Error) { Store.new(@path) }
  end
  def test_independent_stores_jsonb_and_host_connection_survive_close
    host_pool = ActiveRecord::Base.connection_pool if ActiveRecord::Base.connected?
    existing_host_pool = host_pool
    ActiveRecord::Base.establish_connection(@path) unless host_pool
    host_pool ||= ActiveRecord::Base.connection_pool
    peer = Store.new({ adapter: "postgresql", url: @path })
    @store.save(run_record)
    assert_equal run_record, peer.find("run-1")
    peer.instance_variable_get(:@model).connection_pool.with_connection do |database|
      assert_equal "jsonb", database.columns(Store::RUNS_TABLE).find { |column| column.name == "payload" }.sql_type
      refute database.table_exists?("schema_migrations")
    end
    @store.close
    assert_equal run_record, peer.find("run-1")
    assert_same host_pool, ActiveRecord::Base.connection_pool
    host_pool.with_connection { |database| assert_equal 1, database.select_value("SELECT 1") }
  ensure
    peer&.close
    ActiveRecord::Base.remove_connection unless existing_host_pool
  end

  def test_concurrent_first_schema_initialization
    sandbox = PostgresSandbox.new
    gate = Queue.new
    threads = 4.times.map do |index|
      Thread.new do
        gate.pop
        store = Store.new(sandbox.database_url)
        store.save(run_record(id: "concurrent-#{index}"))
      ensure
        store&.close
      end
    end
    4.times { gate << true }
    threads.each(&:value)
    peer = Store.new(sandbox.database_url)
    assert_equal 4, peer.list.length
  ensure
    peer&.close
    sandbox&.close
  end

  def test_non_postgresql_connections_are_rejected_without_credentials
    error = assert_raises(ArgumentError) { Store.new("mysql://user:secret@localhost/db") }
    refute_includes error.message, "secret"
    assert_raises(ArgumentError) { Store.new(adapter: "sqlite3", database: ":memory:") }
  end

  def test_explicit_baseline_requires_same_suite_agent_and_digest
    %w[suite agent suite_digest].each do |field|
      baseline = run_record
      baseline[field] = "different"
      assert_raises(ArgumentError) { Report.new(run_record, baseline: baseline) }
    end
    assert_nil Report.new(run_record).comparison
    assert_raises(ArgumentError) { Report.new(run_record, tolerance: -0.1) }
    assert_raises(ArgumentError) { Report.new(run_record, tolerance: Float::NAN) }
  end

  def test_score_tolerance_and_threshold_transitions
    baseline = run_record(id: "baseline", score: 0.9)
    current = run_record(id: "current", score: 0.85)
    refute Report.new(current, baseline: baseline, tolerance: 0.1).comparison["regressed"]
    comparison = Report.new(current, baseline: baseline, tolerance: 0.01).comparison
    assert comparison["regressed"]
    assert_equal 1, comparison["regressions"].length
    assert_in_delta(-0.05, comparison["score_delta"])
    assert_equal "accuracy", comparison["regressions"][0]["evaluator"]
    current = run_record(id: "current", score: 0.79, passed: false)
    comparison = Report.new(current, baseline: baseline, tolerance: 1.0).comparison
    assert comparison["regressed"], "threshold failure cannot be hidden by score tolerance"
    assert_equal 1, comparison["regressions"].length
    assert_match(/passing to failing/, comparison["regressions"][0]["reason"])
  end

  def test_new_evaluation_errors_are_regressions_even_when_already_failing
    baseline = run_record(id: "baseline", score: 0.0, passed: false)
    current = run_record(id: "current", score: 0.0, passed: false)
    current["cases"][0]["status"] = "error"
    evaluation = current["cases"][0]["evaluations"][0]
    evaluation["score"] = nil
    evaluation["error"] = { "class" => "RuntimeError", "message" => "judge unavailable" }
    comparison = Report.new(current, baseline: baseline, tolerance: 1.0).comparison
    assert comparison["regressed"]
    assert_equal 1, comparison["regressions"].length
    assert_equal 0.0, comparison["regressions"][0]["current_score"]
    assert_match(/raising an error/, comparison["regressions"][0]["reason"])
    recovery = Report.new(baseline, baseline: current, tolerance: 1.0).comparison
    refute recovery["regressed"]
    assert_equal 1, recovery["improvements"].length
  end

  def test_agent_error_is_one_case_regression_and_recovery_is_an_improvement
    baseline = run_record(id: "baseline")
    current = run_record(id: "current", score: 0.0, passed: false)
    current["cases"][0]["status"] = "error"
    current["cases"][0]["error"] = { "class" => "Timeout::Error", "message" => "timed out" }
    current["cases"][0]["evaluations"] = []
    comparison = Report.new(current, baseline: baseline, tolerance: 1.0).comparison
    assert_equal 1, comparison["regressions"].length
    assert_nil comparison["regressions"][0]["evaluator"]
    assert_equal(-1.0, comparison["regressions"][0]["delta"])
    recovery = Report.new(baseline, baseline: current).comparison
    assert_equal 1, recovery["improvements"].length
    refute recovery["regressed"]
  end

  def test_improvements_and_json_comparison_shape
    baseline = run_record(id: "baseline", score: 0.7, passed: false)
    current = run_record(id: "current", score: 0.9)
    report = Report.new(current, baseline: baseline, tolerance: 1.0)
    comparison = report.comparison
    assert_equal "baseline", comparison["baseline_id"]
    assert_equal "current", comparison["current_id"]
    assert comparison["compatible"]
    refute comparison["regressed"]
    assert_equal 1, comparison["improvements"].length
    serialized = JSON.parse(report.to_json)
    assert_equal current, serialized.reject { |key, _value| key == "comparison" }
    assert_equal comparison, serialized["comparison"]
  end

  def test_all_human_formats_include_cases_telemetry_errors_and_comparison
    baseline = run_record(id: "baseline")
    current = run_record(id: "current", score: 0.5, passed: false)
    current["cases"][0]["output"] = "wrong answer"
    current["cases"][0]["evaluations"][0]["reason"] = "incorrect calculation"
    report = Report.new(current, baseline: baseline)
    [report.to_text, report.to_markdown, report.to_html].each do |document|
      ["Answers", "Assistant", "baseline", "wrong answer", "incorrect calculation", "input_tokens", "0.004", "Input", "Expected", "Output", "Assessments"].each do |text|
        # Markdown escapes underscores, but retains all field content.
        assert_includes document.delete("\\"), text
      end
    end
  end

  def test_standalone_html_escapes_untrusted_data_and_markdown_fences
    current = run_record
    attack = '<script>alert("bad")</script>&'
    current["suite"] = attack
    current["cases"][0]["name"] = attack
    current["cases"][0]["output"] = attack
    current["cases"][0]["error"] = { "class" => "Error", "message" => attack }
    current["cases"][0]["evaluations"][0]["reason"] = attack
    html = Report.new(current).to_html
    assert_includes html, "<!doctype html>"
    refute_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
    assert_includes html, "&amp;"
    current["cases"][0]["output"] = "```\n<script>bad</script>\n```"
    markdown = Report.new(current).to_markdown
    assert_includes markdown, "````\n```\n<script>bad</script>\n```\n````"
  end
end
