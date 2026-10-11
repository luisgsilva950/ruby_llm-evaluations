# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require_relative "../../lib/ruby_llm/evaluations"
require_relative "../postgres_helper"

class CLITest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("evaluation-cli-test")
    @sandbox = PostgresSandbox.new
    @database = @sandbox.database_url
    @spec = File.join(@directory, "quality.rb")
    File.write(@spec, <<~RUBY)
      require "ruby_llm/evaluations"
      RubyLLM::Evaluations.define("quality", agent: ->(input) { input }, agent_name: "Agent") do
        evaluate(:quality, threshold: 0.5) { |_output, _test_case| Float(ENV.fetch("QUALITY", "0.9")) }
        question "prompt", name: "answer"
      end
    RUBY
  end

  def teardown
    FileUtils.remove_entry(@directory)
    @sandbox.close
  end

  def cli(*arguments, quality: "0.9")
    Open3.capture3({ "QUALITY" => quality }, RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__),
                  File.expand_path("../../exe/ruby_llm-evaluations", __dir__), *arguments, "--database-url", @database)
  end

  def test_regression_gate_catches_a_score_drop_when_cases_still_pass
    first, error, status = cli("run", @spec, "--format", "json")
    assert status.success?, error
    baseline = JSON.parse(first)
    output, error, status = cli("run", @spec, "--format", "json", "--fail-on-regression", quality: "0.8")
    assert_equal 1, status.exitstatus, error
    current = JSON.parse(output)
    assert_equal 1, current["summary"]["passed"]
    assert_equal baseline["id"], current["comparison"]["baseline_id"]
    assert_equal true, current["comparison"]["regressed"]
    output, error, status = cli("report", baseline["id"], "--format", "json")
    assert status.success?, error
    assert_nil JSON.parse(output)["comparison"], "historical report must not compare to a future run"
  end

  def test_explicit_missing_baseline_does_not_execute_an_agent_run
    _output, error, status = cli("run", @spec, "--baseline", "missing")
    assert_equal 2, status.exitstatus
    assert_includes error, "baseline run not found"
    assert_empty RubyLLM::Evaluations::Run.all
  end
  def test_all_cli_formats_and_history_commands_use_models
    output, error, status = cli("run", @spec, "--format", "json")
    assert status.success?, error
    id = JSON.parse(output).fetch("id")
    %w[text markdown html json].each do |format|
      report, error, status = cli("report", id, "--format", format)
      assert status.success?, error
      assert_includes report, "quality"
    end
    assert_equal id, RubyLLM::Evaluations::Run.first.id
  end
  def test_missing_schema_requires_explicit_migration
    empty = PostgresSandbox.new(migrate: false)
    original = @database
    @database = empty.database_url
    _output, error, status = cli("history")
    assert_equal 2, status.exitstatus
    assert_includes error, "db:migrate"
    output, error, status = cli("db:migrate")
    assert status.success?, error
    assert_includes output, "migrated"
    _output, error, status = cli("run", @spec)
    assert status.success?, error
  ensure
    @database = original
    empty&.close
  end

  def test_explicit_future_baseline_does_not_execute_agent
    definition = TOPLEVEL_BINDING.eval(File.read(@spec), @spec)
    future = Time.now.utc + 3600
    RubyLLM::Evaluations::Run.create!(id: "future", suite: definition.name, agent: definition.agent_name,
      version: definition.version, suite_digest: definition.digest, started_at: future, finished_at: future,
      status: "completed", metadata: {}, summary: {})
    _output, error, status = cli("run", @spec, "--baseline", "future")
    assert_equal 2, status.exitstatus
    assert_includes error, "earlier"
    assert_equal 1, RubyLLM::Evaluations::Run.count
  end
end
