# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require_relative "../postgres_helper"
require_relative "../../lib/ruby_llm/evaluations"

class MigrationTest < Minitest::Test
  E = RubyLLM::Evaluations

  def setup
    @sandbox = PostgresSandbox.new(migrate: false)
    @db = ActiveRecord::Base.connection
  end

  def teardown = @sandbox.close

  def test_fresh_cli_setup_creates_only_current_tables_and_persists_evaluations
    executable = File.expand_path("../../exe/ruby_llm-agent-evaluations", __dir__)
    lib = File.expand_path("../../lib", __dir__)
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", lib, executable,
                                          "db:migrate", "--database-url", @sandbox.database_url)
    assert status.success?, "#{output}\n#{error}"
    assert_equal %w[ruby_llm_evaluations_case_results ruby_llm_evaluations_metric_results ruby_llm_evaluations_runs],
                 @db.tables.grep(/^ruby_llm_evaluations_/).sort
    columns = @db.columns("ruby_llm_evaluations_case_results").map(&:name)
    assert_includes columns, "minimum_scores"
    refute_includes columns, "criteria"

    spec = File.expand_path("../../examples/api_replay_eval.rb", __dir__)
    output, error, status = Open3.capture3({ "AGENT_REVISION" => nil }, RbConfig.ruby, "-I", lib, executable,
                                          "run", spec, "--format", "json", "--database-url", @sandbox.database_url)
    assert status.success?, "#{output}\n#{error}"
    snapshot = JSON.parse(output)
    reopened = E::Run.with_results.find(snapshot.fetch("id"))
    assert_equal ["passed", "passed"], reopened.case_results.map(&:status)
    assert_equal snapshot.fetch("cases"), reopened.snapshot.fetch("cases")
  end

  def test_repeating_setup_keeps_current_runs_available_for_regression
    E.migrate!
    suite = ->(score) do
      E.define("Fresh project", agent: ->(_) { score }, agent_name: "Support") do
        evaluate(:quality) { |output| output }
        question "Return deadline?", expected_answer: "30 days", minimum_scores: { quality: 0.7 }
      end
    end
    baseline = E.run(suite.call(0.95))
    original = baseline.snapshot

    E.migrate!
    assert_equal original, E::Run.with_results.find(baseline.id).snapshot
    current = E.run(suite.call(0.8))
    assert_equal "passed", current.case_results.first.status
    assert_equal baseline.id, current.previous.id
    comparison = E::Report.new(current, baseline: current.previous).comparison
    assert comparison.fetch("regressed")
    assert_equal "quality", comparison.fetch("regressions").first.fetch("evaluator")
  end
end
