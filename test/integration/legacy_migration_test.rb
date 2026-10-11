# frozen_string_literal: true
require "minitest/autorun"
require_relative "../postgres_helper"
require_relative "../../lib/ruby_llm/evaluations"

class LegacyMigrationTest < Minitest::Test
  E = RubyLLM::Evaluations
  def setup
    @sandbox = PostgresSandbox.new(migrate: false)
    @db = ActiveRecord::Base.connection
    @db.execute("CREATE TABLE ruby_llm_evaluations_schema_versions (version integer PRIMARY KEY)")
    @db.execute("CREATE TABLE ruby_llm_evaluations_runs (sequence bigserial PRIMARY KEY, run_id text NOT NULL UNIQUE, suite text NOT NULL, agent text NOT NULL, suite_digest text NOT NULL, started_at timestamptz NOT NULL, payload jsonb NOT NULL)")
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

  def insert_legacy(id)
    payload = legacy_payload(id)
    @db.execute("INSERT INTO ruby_llm_evaluations_runs (run_id,suite,agent,suite_digest,started_at,payload) VALUES (#{@db.quote(id)},'Legacy','Support','original-digest','2026-01-01T00:00:00Z',#{@db.quote(JSON.generate(payload))}::jsonb)")
  end

  def test_real_jsonb_history_is_cut_over_without_losing_evidence
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
    @db.execute("INSERT INTO ruby_llm_evaluations_schema_versions VALUES (99)")
    insert_legacy("unknown")
    assert_raises(StandardError) { E.migrate! }
    assert_equal "unknown", @db.select_value("SELECT run_id FROM ruby_llm_evaluations_runs")
    assert_equal 99, @db.select_value("SELECT version FROM ruby_llm_evaluations_schema_versions")
  end
end
