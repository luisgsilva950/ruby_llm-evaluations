# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "action_dispatch"
require "rack/mock"
require "nokogiri"
require_relative "../postgres_helper"
require_relative "../../lib/ruby_llm/evaluations"

class RailsMountTest < Minitest::Test
  E = RubyLLM::Evaluations

  def setup
    @sandbox = PostgresSandbox.new
    @store = E::Store.new(@sandbox.database_url)
    @suite = E::Suite.new("Mounted <support>", agent: ->(input) { input }, agent_name: "Ruby callable")
    @suite.test("Answer", input: "<script>alert('agent')</script>", expected: "<script>alert('agent')</script>")
    @suite.evaluate("accuracy", using: E::Evaluators.exact_match)
    runner = E::Runner.new(store: @store)
    @baseline = runner.run(@suite)
    @current = runner.run(@suite)
    @dashboard = E::Dashboard.new(store: @store)
    app = @dashboard
    @routes = ActionDispatch::Routing::RouteSet.new
    @routes.draw { mount app => "/evaluations" }
    @http = Rack::MockRequest.new(@routes)
  end

  def teardown
    @store&.close
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
      assert_includes document.css("a").map { |link| link["href"] }, "/evaluations/runs/#{@current.fetch('id')}"
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
    assert_equal [@current.fetch("id")], JSON.parse(listing.body).map { |run| run.fetch("id") }
  end

  def test_mounted_detail_baseline_asset_and_download
    detail = @http.get("/evaluations/runs/#{@current.fetch('id')}")
    assert_equal 200, detail.status
    document = Nokogiri::HTML(detail.body)
    assert_mounted_links(document)
    assert_equal "/evaluations/", document.at_css(".back-link")["href"]
    assert_includes document.css("a").map { |link| link["href"] }, "/evaluations/runs/#{@baseline.fetch('id')}"
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
    ["/evaluations/", "/evaluations/runs/#{@current.fetch('id')}", "/evaluations/assets/dashboard.css", "/evaluations/api/runs/#{@current.fetch('id')}?download=1"].each do |url|
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
    assert_equal 2, @store.list.length
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

  def test_rails_configuration_hash_does_not_replace_or_disconnect_host_pool
    previous = ActiveRecord::Base.connection_db_config if ActiveRecord::Base.connected?
    ActiveRecord::Base.establish_connection(@sandbox.database_url)
    pool = ActiveRecord::Base.connection_pool
    connection = ActiveRecord::Base.connection
    config = pool.db_config.configuration_hash
    store = E::Store.new(config)
    assert_equal @current, store.find(@current.fetch("id"))
    store.close
    assert_same pool, ActiveRecord::Base.connection_pool
    assert_same connection, ActiveRecord::Base.connection
    assert_equal 42, connection.select_value("SELECT 42")
  ensure
    store&.close
    ActiveRecord::Base.remove_connection
    ActiveRecord::Base.establish_connection(previous) if previous
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
