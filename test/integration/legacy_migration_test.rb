# frozen_string_literal: true
require "minitest/autorun"
require_relative "../postgres_helper"
require_relative "../../lib/ruby_llm/evaluations"

class LegacyMigrationTest < Minitest::Test
  E = RubyLLM::Evaluations
  def setup
    @sandbox = PostgresSandbox.new(migrate: false)
    @db = ActiveRecord::Base.connection
  end
  def teardown = @sandbox.close

  def legacy_payload(id)
    { id: id, suite: "Legacy", agent: "Support", suite_digest: "original-digest", version: "1",
      started_at: "2026-01-01T00:00:00Z", finished_at: "2026-01-01T00:00:01Z", status: "completed",
      metadata: { revision: id }, summary: { cases: 2, errors: 1, score: 0.5 },
      cases: [
        { id: "second-alphabetically", name: "First case", input: { prompt: "returns" }, expected: "30 days", metadata: { important_facts: ["30 days"] },
          expected_actions: [], actions: [], output: "30 days", status: "passed", duration_ms: 1, input_tokens: 2, output_tokens: 3, cost: 0.01,
          response_metadata: { model: "legacy" }, error: nil,
          evaluations: [{ name: "z-last", threshold: 0.9, score: 1, passed: true, reason: "preserved", error: nil },
                        { name: "a-first", threshold: 0.5, score: nil, passed: false, reason: nil, error: { class: "RuntimeError", message: "judge failed" } }] },
        { id: "a-first", name: "Second case", input: "offline", expected: nil, metadata: {}, output: nil, status: "error", duration_ms: 2,
          error: { class: "Timeout::Error", message: "offline" }, evaluations: [] }
      ] }
  end

  def create_legacy_tables
    @db.execute("CREATE TABLE ruby_llm_evaluations_schema_versions (version integer PRIMARY KEY)")
    @db.execute("CREATE TABLE ruby_llm_evaluations_runs (sequence bigserial PRIMARY KEY, run_id text NOT NULL UNIQUE, suite text NOT NULL, agent text NOT NULL, suite_digest text NOT NULL, started_at timestamptz NOT NULL, payload jsonb NOT NULL)")
  end

  def insert_legacy(id)
    payload = legacy_payload(id)
    @db.execute("INSERT INTO ruby_llm_evaluations_runs (run_id,suite,agent,suite_digest,started_at,payload) VALUES (#{@db.quote(id)},'Legacy','Support','original-digest','2026-01-01T00:00:00Z',#{@db.quote(JSON.generate(payload))}::jsonb)")
  end

  def test_real_jsonb_history_is_cut_over_without_losing_evidence
    create_legacy_tables
    @db.execute("INSERT INTO ruby_llm_evaluations_schema_versions VALUES (1)")
    insert_legacy("legacy-1")
    insert_legacy("legacy-2")
    E.migrate!
    run = E::Run.with_results.find("legacy-2")
    assert_equal "legacy-1", run.previous.id
    assert_equal %w[legacy-2 legacy-1], E::Run.recent.pluck(:id)
    assert_equal ["second-alphabetically", "a-first"], run.case_results.map(&:case_id)
    snapshot = run.snapshot
    first, second = snapshot["cases"]
    assert_equal({ "prompt" => "returns" }, first["question"])
    assert_equal "30 days", first["expected_answer"]
    assert_equal({ "z-last" => 0.9, "a-first" => 0.5 }, first["minimum_scores"])
    assert_equal "original-digest", run.suite_digest
    assert_equal %w[z-last a-first], first["metrics"].map { |metric| metric["name"] }
    assert_equal "judge failed", first["metrics"][1]["error"]["message"]
    assert_equal "offline", second["error"]["message"]
    assert_equal 0.01, first["cost"]
    assert_equal({ "model" => "legacy" }, first["response_metadata"])
    assert_equal ["30 days"], first["metadata"]["important_facts"]
    refute @db.table_exists?("ruby_llm_evaluations_schema_versions")
    refute_includes @db.columns("ruby_llm_evaluations_runs").map(&:name), "payload"
    E.migrate!
    assert_equal 2, E::Run.count
  end

  def test_unknown_legacy_version_is_rejected_without_destroying_history
    create_legacy_tables
    @db.execute("INSERT INTO ruby_llm_evaluations_schema_versions VALUES (99)")
    insert_legacy("unknown")
    assert_raises(StandardError) { E.migrate! }
    assert_equal "unknown", @db.select_value("SELECT run_id FROM ruby_llm_evaluations_runs")
    assert_equal 99, @db.select_value("SELECT version FROM ruby_llm_evaluations_schema_versions")
  end

  # Captured from the shipped criteria DSL before the public rename.
  UPGRADE_DIGEST = "2ad9f2240b3df500c52c0280544c605cd24aeaeb288e3d02dfe0624fd6a963e8"

  def upgrade_suite(score)
    E.define("Upgrade", agent: ->(_) { score }, agent_name: "Support") do
      evaluate(:quality) { |output, _context| output }
      question "Answer", expected_answer: "Reference", minimum_scores: { quality: 0.7 }, id: "answer"
    end
  end

  def test_existing_criteria_column_history_keeps_identity_and_remains_a_baseline
    context = ActiveRecord::MigrationContext.new([E::MIGRATIONS_PATH])
    context.migrate(20261011000000)
    assert @db.column_exists?(:ruby_llm_evaluations_case_results, :criteria)
    [CreateAgentEvaluationHistory::MigratedRun, CreateAgentEvaluationHistory::MigratedCase,
     CreateAgentEvaluationHistory::MigratedMetric].each(&:reset_column_information)
    %w[old-1 old-2].each_with_index do |id, index|
      run = CreateAgentEvaluationHistory::MigratedRun.create!(
        id: id, suite: "Upgrade", agent: "Support", version: "1", suite_digest: UPGRADE_DIGEST,
        started_at: "2026-01-0#{index + 1}T00:00:00Z", finished_at: "2026-01-0#{index + 1}T00:00:01Z",
        status: "completed", summary: { cases: 1, score: 0.95 })
      item = CreateAgentEvaluationHistory::MigratedCase.create!(
        run_id: run.id, position: 0, case_id: "answer", name: "Answer", question: "Answer",
        expected_answer: "Reference", criteria: { quality: 0.7 }, output: 0.95,
        status: "passed", duration_ms: 1)
      CreateAgentEvaluationHistory::MigratedMetric.create!(
        case_result_id: item.id, position: 0, name: "quality", threshold: 0.7,
        score: 0.95, passed: true, reason: "historical")
    end
    run_rows = CreateAgentEvaluationHistory::MigratedRun.order(:sequence).map(&:attributes)
    case_rows = CreateAgentEvaluationHistory::MigratedCase.order(:id).map(&:attributes)
    metric_rows = CreateAgentEvaluationHistory::MigratedMetric.order(:id).map(&:attributes)

    E.migrate!
    [E::Run, E::CaseResult, E::MetricResult].each(&:reset_column_information)
    refute @db.column_exists?(:ruby_llm_evaluations_case_results, :criteria)
    assert @db.column_exists?(:ruby_llm_evaluations_case_results, :minimum_scores)
    assert_equal run_rows, E::Run.order(:sequence).map(&:attributes)
    assert_equal case_rows.map { |row| row.merge("minimum_scores" => row["criteria"]).except("criteria") },
                 E::CaseResult.order(:id).map(&:attributes)
    assert_equal metric_rows, E::MetricResult.order(:id).map(&:attributes)
    historical = E::Run.with_results.find("old-2")
    assert_equal "old-1", historical.previous.id
    assert_equal({ "quality" => 0.7 }, historical.snapshot["cases"][0]["minimum_scores"])
    assert_equal "old-2", historical.case_results.first.run.id
    assert_equal historical.case_results.first.id, historical.case_results.first.metric_results.first.case_result.id

    suite = upgrade_suite(0.8)
    assert_equal UPGRADE_DIGEST, suite.digest
    current = E::Runner.new.run(suite)
    assert_equal "old-2", current.previous.id
    assert_equal "passed", current.case_results.first.status
    comparison = E::Report.new(current, baseline: current.previous).comparison
    assert comparison["regressed"]
    assert_equal "quality", comparison["regressions"].first["evaluator"]
    assert_equal 0.7, current.case_results.first.metric_results.first.threshold
  end

  def test_minimum_scores_are_applied_on_first_run_without_a_baseline
    E.migrate!
    [E::Run, E::CaseResult, E::MetricResult].each(&:reset_column_information)
    first = E::Runner.new.run(upgrade_suite(0.6))
    assert_nil first.previous
    assert_nil E::Report.new(first).comparison
    assert_equal "failed", first.case_results.first.status
    metric = first.case_results.first.metric_results.first
    assert_equal 0.6, metric.score
    assert_equal 0.7, metric.threshold
    refute metric.passed
  end
end
