# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "rbconfig"
require "mysql2"
require_relative "../postgres_helper"
require_relative "../../lib/ruby_llm/evaluations"

class DatabasePortabilityTest < Minitest::Test
  E = RubyLLM::Evaluations
  MODELS = [E::Run, E::CaseResult, E::MetricResult].freeze
  MYSQL_URL = "mysql2://root:dev-only@127.0.0.1:53306/mysql"

  %i[sqlite postgresql mysql].each do |adapter|
    define_method("test_#{adapter}_roundtrip_reconnect_history_and_reports") do
      with_database(adapter) do |database_url|
        cli(database_url, "db:migrate")
        reset_models
        values = ["quoted \"answer\"\n雪", 42, 0.125, true, false, nil,
                  { "nested" => [true, false, nil, { "number" => 7, "empty" => [] }] },
                  "large output 雪\n" * 10_000]
        metadata = { "nested" => [true, false, nil, { "revision" => 3 }] }
        pool = ActiveRecord::Base.connection_pool
        connection = ActiveRecord::Base.connection
        baseline = E.run(roundtrip_suite(values, score: 0.95), metadata: metadata)
        current = E.run(roundtrip_suite(values, score: 0.8), metadata: metadata)
        original = current.snapshot

        assert_same pool, ActiveRecord::Base.connection_pool
        MODELS.each { |model| assert_same pool, model.connection_pool }
        assert_same connection, ActiveRecord::Base.connection
        assert_equal 42, connection.select_value("SELECT 42")
        assert_match(/\A[0-9a-f-]{36}\z/, current.id)
        assert_operator current.sequence, :>, baseline.sequence

        ActiveRecord::Base.remove_connection
        ActiveRecord::Base.establish_connection(database_url)
        reset_models
        reopened = E::Run.with_results.find(current.id)
        assert_equal original, reopened.snapshot
        assert_equal metadata, reopened.metadata
        assert_equal values, reopened.case_results.map(&:question)
        assert_equal values, reopened.case_results.map(&:expected_answer)
        assert_equal values, reopened.case_results.map(&:output)
        reopened.case_results.each do |result|
          assert_equal metadata, result.metadata
          assert_equal metadata, result.response_metadata
          assert_equal({ "quality" => 0.7 }, result.minimum_scores)
          assert_nil result.error_details
          assert_equal reopened.id, result.run.id
          assert_equal result.id, result.metric_results.first.case_result.id
          assert_equal true, result.metric_results.first.passed
        end
        assert_equal baseline.id, reopened.previous.id
        assert_equal [current.id, baseline.id], E::Run.recent.pluck(:id)
        report = E::Report.new(reopened, baseline: reopened.previous)
        assert report.comparison.fetch("regressed")
        assert_in_delta(-0.15, report.comparison.fetch("score_delta"), 1e-12)
        assert_equal original, JSON.parse(report.to_json).except("comparison")

        history = cli(database_url, "history", "--suite", "Portable answers", "--agent", "Echo")
        assert_operator history.index(current.id), :<, history.index(baseline.id)
        explicit = JSON.parse(cli(database_url, "report", current.id, "--baseline", baseline.id, "--format", "json"))
        assert_equal original, explicit.except("comparison")
        assert_equal baseline.id, explicit.fetch("comparison").fetch("baseline_id")
        assert_nil JSON.parse(cli(database_url, "report", baseline.id, "--format", "json")).fetch("comparison")
      end
    end

    define_method("test_#{adapter}_chronological_and_same_timestamp_baselines") do
      with_database(adapter) do |database_url|
        E.migrate!
        timestamp = Time.utc(2026, 1, 2, 3, 4, 5, 123456)
        future = run_record(started_at: timestamp + 86_400)
        first = run_record(started_at: timestamp)
        older = run_record(started_at: timestamp - 86_400)
        incompatible = run_record(started_at: timestamp, suite_digest: "changed-definition")
        second = run_record(started_at: timestamp)
        reconnect(database_url)

        assert_equal [future.id, second.id, incompatible.id, first.id, older.id], E::Run.recent.pluck(:id)
        assert_equal older.id, E::Run.find(first.id).previous.id
        assert_equal first.id, E::Run.find(second.id).previous.id
        assert_equal second.id, E::Run.find(future.id).previous.id
        assert_nil E::Run.find(older.id).previous
        assert_equal timestamp, E::Run.find(second.id).started_at
        assert_operator second.sequence, :>, first.sequence
        assert_raises(ArgumentError) { E::Report.new(E::Run.find(first.id), baseline: E::Run.find(second.id)) }
        assert_raises(ArgumentError) { E::Report.new(E::Run.find(second.id), baseline: E::Run.find(incompatible.id)) }
      end
    end

    define_method("test_#{adapter}_atomic_append_only_graph_and_foreign_keys") do
      with_database(adapter) do |_database_url|
        E.migrate!
        run = run_record
        snapshot = run.snapshot
        counts = MODELS.map(&:count)
        assert_raises(ActiveRecord::RecordNotUnique) { run_record(id: run.id) }
        assert_equal counts, MODELS.map(&:count)
        assert_equal snapshot, E::Run.with_results.find(run.id).snapshot
        assert_raises(ActiveRecord::RecordInvalid) do
          run_record { |attributes| attributes[:case_results_attributes][0][:metric_results_attributes][0][:threshold] = 2 }
        end
        assert_equal counts, MODELS.map(&:count)

        result = run.case_results.first
        orphan_case = result.attributes.except("id").merge("run_id" => SecureRandom.uuid)
        assert_raises(ActiveRecord::InvalidForeignKey) { E::CaseResult.insert_all!([orphan_case]) }
        orphan_metric = result.metric_results.first.attributes.except("id").merge("case_result_id" => -1)
        assert_raises(ActiveRecord::InvalidForeignKey) { E::MetricResult.insert_all!([orphan_metric]) }
        assert_raises(ActiveRecord::InvalidForeignKey) { E::Run.where(id: run.id).delete_all }
        assert_raises(ActiveRecord::InvalidForeignKey) { E::CaseResult.where(id: result.id).delete_all }
        [run, result, result.metric_results.first].each do |record|
          assert_raises(ActiveRecord::ReadOnlyRecord) { record.update!(record.attributes.except("id")) }
        end
        assert_equal counts, MODELS.map(&:count)
        assert_equal snapshot, E::Run.with_results.find(run.id).snapshot
      end
    end

    define_method("test_#{adapter}_identifiers_remain_exact_with_default_database_collation") do
      with_database(adapter) do |_database_url|
        E.migrate!
        identifiers = ["Answer", "answer", "answer "]
        metrics = ["Quality", "quality", "quality "]
        ["Assistant", "assistant", "ássistant", "assistant "].each do |agent_name|
          suite = E.define("Exact identities", agent: ->(input) { input }, agent_name: agent_name) do
            metrics.each { |metric| evaluate(metric) { 1.0 } }
            identifiers.each { |id| question "Same answer", id: id, expected_answer: "Same answer" }
          end
          run = E.run(suite)
          assert_nil run.previous, "Distinct agent identities must not share a baseline"
          assert_equal agent_name, E::Run.find(run.id).agent
          assert_equal identifiers, run.case_results.map(&:case_id)
          run.case_results.each { |result| assert_equal metrics, result.metric_results.map(&:name) }
        end
      end
    end

    define_method("test_#{adapter}_migration_down_and_up_allows_a_fresh_run") do
      with_database(adapter) do |_database_url|
        E.migrate!
        old = E.run(roundtrip_suite([true, false, nil], score: 0.9))
        ActiveRecord::MigrationContext.new([E::MIGRATIONS_PATH]).migrate(0)
        reset_models
        assert_raises(E::Error) { E.run(roundtrip_suite([true, false, nil], score: 0.9)) }
        E.migrate!
        fresh = E.run(roundtrip_suite([true, false, nil], score: 0.9))
        assert_equal [true, false, nil], fresh.case_results.map(&:output)
        assert_nil fresh.previous
        assert_raises(ActiveRecord::RecordNotFound) { E::Run.find(old.id) }
      end
    end
    define_method("test_#{adapter}_structured_components_survive_reconnection_and_regression") do
      with_database(adapter) do |database_url|
        E.migrate!
        payload = { "label" => "Returns within 30 days 雪", "values" => [true, false, nil, 42], "large" => "UI data" * 20_000 }
        components = [{ "protocol" => "a2ui", "version" => "0.8", "payload" => payload }]
        agent = ->(_input) { E::Response.new(output: nil, components: components, metadata: { "model" => "local" }) }
        check = E::Evaluators.response_components(protocol: "a2ui", version: "0.8") { |items, _context| items.first.fetch("payload").fetch("label") == "Returns within 30 days 雪" }
        definition = E.define("Portable UI", agent: agent) do
          evaluate :ui, using: check
          question "render"
        end
        baseline = E.run(definition)
        components.first["payload"]["label"] = "Returns within 7 days 雪"
        current = E.run(definition)
        reconnect(database_url)
        reopened = E::Run.with_results.find(current.id)
        assert_equal "failed", reopened.case_results.first.status
        assert_nil reopened.case_results.first.output
        assert_equal components, reopened.case_results.first.components
        assert_equal "Returns within 30 days 雪", E::Run.find(baseline.id).case_results.first.components.first.fetch("payload").fetch("label")
        report = E::Report.new(reopened, baseline: reopened.previous)
        assert report.comparison.fetch("regressed")
        assert_equal components, JSON.parse(report.to_json).fetch("cases").first.fetch("components")
      end
    end

  end

  private

  def roundtrip_suite(values, score:)
    metadata = { "nested" => [true, false, nil, { "revision" => 3 }] }
    agent = ->(input) { E::Response.new(output: input, metadata: metadata, input_tokens: 2, output_tokens: 3, cost: 0.004) }
    E.define("Portable answers", agent: agent, agent_name: "Echo") do
      evaluate(:quality) { score }
      values.each_with_index do |value, index|
        question value, name: "Value #{index}", id: "value-#{index}", expected_answer: value,
                       minimum_scores: { quality: 0.7 }, metadata: metadata
      end
    end
  end

  def run_record(id: SecureRandom.uuid, started_at: Time.utc(2026, 1, 1), suite_digest: "portable-definition")
    attributes = {
      id: id, suite: "Chronology", agent: "Echo", version: "1", suite_digest: suite_digest,
      started_at: started_at, finished_at: started_at, status: "completed", metadata: {},
      summary: { cases: 1, passed: 1, failed: 0, errors: 0, pass_rate: 1.0, score: 0.9 },
      case_results_attributes: [{ case_id: "answer", name: "Answer", position: 0, question: "Question?",
        expected_answer: "Answer", output: "Answer", minimum_scores: { quality: 0.7 }, metadata: {},
        status: "passed", duration_ms: 0.1, response_metadata: {},
        metric_results_attributes: [{ name: "quality", position: 0, threshold: 0.7, score: 0.9, passed: true }] }]
    }
    yield attributes if block_given?
    E::Run.create!(attributes)
  end

  def cli(database_url, *arguments)
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__),
      File.expand_path("../../exe/ruby_llm-agent-evaluations", __dir__), *arguments, "--database-url", database_url)
    assert status.success?, "#{arguments.first} failed (#{status.exitstatus}):\n#{output}\n#{error}"
    output
  end

  def reconnect(database_url)
    ActiveRecord::Base.remove_connection
    ActiveRecord::Base.establish_connection(database_url)
    reset_models
  end

  def reset_models
    MODELS.each(&:reset_column_information)
  end

  def with_database(adapter)
    prior_pool = ActiveRecord::Base.connection_handler.retrieve_connection_pool(ActiveRecord::Base.connection_specification_name)
    previous = prior_pool&.db_config
    case adapter
    when :postgresql
      sandbox = PostgresSandbox.new(migrate: false)
      reset_models
      yield sandbox.database_url
    when :sqlite
      directory = Dir.mktmpdir("evaluation-sqlite-")
      database_url = "sqlite3:#{File.join(directory, 'history.sqlite3')}"
      ActiveRecord::Base.establish_connection(database_url)
      reset_models
      yield database_url
    when :mysql
      source = ENV.fetch("TEST_MYSQL_DATABASE_URL", MYSQL_URL)
      config = ActiveRecord::DatabaseConfigurations::UrlConfig.new("test", "mysql", source).configuration_hash
      admin = Mysql2::Client.new(**config.except(:adapter))
      database = "eval_test_#{SecureRandom.hex(12)}"
      admin.query("CREATE DATABASE `#{database}` CHARACTER SET utf8mb4")
      created = true
      scoped = URI.parse(source)
      scoped.path = "/#{database}"
      ActiveRecord::Base.establish_connection(scoped.to_s)
      reset_models
      yield scoped.to_s
    end
  ensure
    begin
      if sandbox
        sandbox.close
      elsif directory || created
        ActiveRecord::Base.remove_connection
      end
    ensure
      begin
        admin.query("DROP DATABASE `#{database}`") if created
      ensure
        begin
          admin&.close
          FileUtils.remove_entry(directory) if directory
        ensure
          if previous
            ActiveRecord::Base.establish_connection(previous)
          else
            ActiveRecord::Base.remove_connection
          end
          reset_models if previous
        end
      end
    end
  end
end
