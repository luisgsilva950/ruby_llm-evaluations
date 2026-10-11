# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "rails"
require "rails/application"
require "active_record/railtie"
require "action_dispatch"
require "rack/mock"
require "nokogiri"
require "tmpdir"
require_relative "../postgres_helper"
require_relative "../../lib/ruby_llm/evaluations"

class RailsMountTest < Minitest::Test
  E = RubyLLM::Evaluations

  def setup
    @sandbox = PostgresSandbox.new
    @suite = E::Suite.new("Mounted <support>", agent: ->(input) { input }, agent_name: "Ruby callable")
    @suite.question( "<script>alert('agent')</script>", name: "Answer", expected_answer: "<script>alert('agent')</script>")
    @suite.evaluate("accuracy", using: E::Evaluators.exact_match)
    runner = E::Runner.new
    @baseline = runner.run(@suite)
    @current = runner.run(@suite)
    @dashboard = E::Dashboard.new
    app = @dashboard
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { mount app => "/evaluations" }
    @http = Rack::MockRequest.new(@routes)
  end

  def teardown
    @sandbox&.close
  end

  def test_real_runner_history_filters_and_navigation_stay_mounted
    ["/evaluations", "/evaluations/"].each do |url|
      response = @http.get(url)
      assert_equal 200, response.status
      document = Nokogiri::HTML(response.body)
      assert_equal "/evaluations/assets/dashboard.css", document.at_css('link[rel="stylesheet"]')["href"]
      assert_equal "/evaluations/", document.at_css("form")["action"]
      assert_mounted_links(document)
      assert_includes document.css("a").map { |link| link["href"] }, "/evaluations/runs/#{@current.id}"
      assert_nil document.at_css("script")
    end
    query = URI.encode_www_form(suite: @suite.name, agent: @suite.agent_name, limit: 1)
    filtered = @http.get("/evaluations/?#{query}")
    assert_equal 200, filtered.status
    assert_equal 1, Nokogiri::HTML(filtered.body).css(".history-table tbody tr").length
    empty = @http.get("/evaluations/?suite=absent")
    assert_equal 200, empty.status
    assert_mounted_links(Nokogiri::HTML(empty.body))
    listing = @http.get("/evaluations/api/runs?#{query}")
    assert_equal [@current.id], JSON.parse(listing.body).map { |run| run.fetch("id") }
    blank_filters = Nokogiri::HTML(@http.get("/evaluations/?suite=&agent=").body)
    %w[suite agent].each do |field|
      assert_equal 1, blank_filters.css("##{field} option[value='']").size
      assert blank_filters.css("##{field} option").all? { |option| !option.text.empty? }
    end
  end

  def test_mounted_detail_baseline_asset_and_download
    detail = @http.get("/evaluations/runs/#{@current.id}")
    assert_equal 200, detail.status
    document = Nokogiri::HTML(detail.body)
    assert_mounted_links(document)
    assert_equal "/evaluations/", document.at_css(".back-link")["href"]
    assert_includes document.css("a").map { |link| link["href"] }, "/evaluations/runs/#{@baseline.id}"
    download_url = document.at_css("a[download]")["href"]
    report = @http.get(download_url)
    assert_equal 200, report.status
    assert_match(/attachment; filename="evaluation-/, report["content-disposition"])
    assert_equal JSON.parse(E::Report.new(@current, baseline: @baseline).to_json), JSON.parse(report.body)
    asset = @http.get(document.at_css('link[rel="stylesheet"]')["href"])
    assert_equal 200, asset.status
    assert_equal "text/css; charset=utf-8", asset["content-type"]
    refute_empty asset.body
    assert_equal "nosniff", detail["x-content-type-options"]
    assert_includes detail["content-security-policy"], "form-action 'self'"
    missing = @http.get("/evaluations/runs/missing")
    assert_equal 404, missing.status
    assert_mounted_links(Nokogiri::HTML(missing.body))
  end

  def test_head_and_post_preserve_read_only_contract
    ["/evaluations/", "/evaluations/runs/#{@current.id}", "/evaluations/assets/dashboard.css", "/evaluations/api/runs/#{@current.id}?download=1"].each do |url|
      get = @http.get(url)
      head = @http.request("HEAD", url)
      assert_equal get.status, head.status
      assert_equal get["content-length"], head["content-length"]
      assert_equal "", head.body
      post = @http.post(url)
      assert_equal 405, post.status
      assert_equal "GET, HEAD", post["allow"]
      assert_mounted_links(Nokogiri::HTML(post.body))
    end
    assert_equal 2, E::Run.count
  end

  def test_mount_prefix_is_validated_encoded_and_request_local
    direct = Rack::MockRequest.new(@dashboard)
    ["//evil.example", "/../escape", "/bad%2fpath", "/bad?query", "/bad#fragment", "/bad\\path", "/bad%00", "relative"].each do |prefix|
      assert_equal 400, direct.get("/", "SCRIPT_NAME" => prefix).status, prefix
    end
    safe = direct.get("/", "SCRIPT_NAME" => '/team "<>&/evaluations')
    assert_equal 200, safe.status
    assert_equal "/team%20%22%3C%3E%26/evaluations/", Nokogiri::HTML(safe.body).at_css("form")["action"]
    @http.get("/evaluations/")
    root = direct.get("/")
    assert_equal 200, root.status
    assert_equal "/", Nokogiri::HTML(root.body).at_css("form")["action"]
    assert_equal "/assets/dashboard.css", Nokogiri::HTML(root.body).at_css('link[rel="stylesheet"]')["href"]
  end

  def test_unjudged_runs_keep_outputs_and_do_not_plot_fabricated_scores
    suite = E.define("Unjudged <support>", agent: ->(_) { "30 days" }) do
      question "Return deadline?", expected_answer: "30 days"
    end
    E.run(suite)
    current = E.run(suite)
    history = @http.get("/evaluations/?suite=#{URI.encode_www_form_component(suite.name)}")
    assert_equal 200, history.status
    document = Nokogiri::HTML(history.body)
    assert_empty document.css(".trend-chart .chart-point")
    assert_empty document.css(".stat-card strong").select { |value| value.text == "0.000" || value.text == "100.0%" }
    detail = @http.get("/evaluations/runs/#{current.id}")
    assert_equal 200, detail.status
    assert_equal "30 days", Nokogiri::HTML(detail.body).at_css(".output-payload pre").text
    exported = JSON.parse(@http.get("/evaluations/api/runs/#{current.id}?download=1").body)
    assert_nil exported["summary"]["score"]
    assert_nil exported["comparison"]["score_delta"]
    assert_equal "not_evaluated", exported["cases"][0]["status"]
    assert_empty exported["cases"][0]["metrics"]
  end

  def test_run_shares_host_pool_and_normal_model_associations
    pool = ActiveRecord::Base.connection_pool
    connection = ActiveRecord::Base.connection
    result = E.run(@suite)
    assert_instance_of E::Run, result
    assert_same pool, ActiveRecord::Base.connection_pool
    [E::Run, E::CaseResult, E::MetricResult].each { |model| assert_same pool, model.connection_pool }
    assert_same connection, ActiveRecord::Base.connection
    assert_equal 42, connection.select_value("SELECT 42")
    assert_equal result.id, result.case_results.first.run.id
    assert_equal result.case_results.first.id, result.case_results.first.metric_results.first.case_result.id
  end

  def test_real_rails_application_mounts_engine_and_normal_migrations
    E::Engine.instance # Register the engine before Rails assembles application railties.
    host_root = Dir.mktmpdir("evaluation-rails-host")
    FileUtils.mkdir_p(File.join(host_root, "config"))
    File.write(File.join(host_root, "config/routes.rb"), "Rails.application.routes.draw { mount RubyLLM::Evaluations::Engine => '/evaluations' }\n")
    app = Class.new(Rails::Application)
    app.config.root = host_root
    app.config.eager_load = true
    app.config.secret_key_base = "integration-test-secret-" * 4
    app.config.hosts.clear
    app.config.logger = Logger.new(File::NULL)
    previous_application = Rails.application
    previous_url = ENV["DATABASE_URL"]
    ENV["DATABASE_URL"] = @sandbox.database_url
    application = app.instance
    Rails.application = application
    application.initialize!
    response = Rack::MockRequest.new(application).get("/evaluations/")
    assert_equal 200, response.status, response.body
    assert_includes response.body, @current.id
    paths = E::Engine.paths["db/migrate"].existent
    refute_empty paths
    Dir.mktmpdir("host-migrations") do |directory|
      copied = ActiveRecord::Migration.copy(directory, { ruby_llm_evaluations: paths.first })
      refute_empty copied
      installed = PostgresSandbox.new(migrate: false)
      begin
        context = ActiveRecord::MigrationContext.new(directory)
        context.migrate
        assert_empty context.migrations.reject { |migration| context.get_all_versions.include?(migration.version) }
        assert E::Run.table_exists?
        assert E::CaseResult.table_exists?
        assert E::MetricResult.table_exists?
      ensure
        installed.close
      end
    end
  ensure
    Rails.application = previous_application
    previous_url.nil? ? ENV.delete("DATABASE_URL") : ENV["DATABASE_URL"] = previous_url
    FileUtils.remove_entry(host_root) if host_root
  end

  private

  def assert_mounted_links(document)
    document.css("a[href], link[href], form[action]").each do |element|
      url = element["href"] || element["action"]
      next if url.start_with?("#")
      assert url.start_with?("/evaluations/"), "escaped mount: #{url.inspect}"
    end
  end
end
