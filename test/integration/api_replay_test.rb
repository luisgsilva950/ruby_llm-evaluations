# frozen_string_literal: true

require "minitest/autorun"
require "net/http"
require "faraday"
require "tmpdir"
require "json"
require_relative "../../lib/ruby_llm/evaluations"
require_relative "../postgres_helper"

class ApiReplayIntegrationTest < Minitest::Test
  E = RubyLLM::Evaluations
  URL = "https://shipping.example/orders"
  BODY_FILE = "../fixtures/api_replay/order.json"

  def setup = @sandbox = PostgresSandbox.new
  def teardown = @sandbox&.close

  def definition(agent:, request: {}, response: { json: { status: "ready" } }, allow_hosts: [])
    E.define("Shipping replay", agent: agent, agent_name: "ShippingAgent") do
      evaluate :exact, using: E::Evaluators.exact_match
      question "Track order 42", expected_answer: "ready" do
        api_interactions(allow_hosts: allow_hosts) do
          expect_request(method: :get, url: URL, query: { id: "42" }, **request).respond_with(**response)
        end
      end
    end
  end

  def persisted_case(suite)
    run = E.run(suite)
    E::Run.find(run.id).case_results.first
  end

  def net_get(query = "id=42")
    Net::HTTP.get_response(URI("#{URL}?#{query}"))
  end

  def test_existing_webmock_stubs_cannot_bypass_replay_and_are_restored
    require "webmock"
    registry = WebMock::StubRegistry.instance
    original_stubs = registry.request_stubs.dup
    config = WebMock::Config.instance
    original_config = config.instance_variables.to_h { |key| [key, config.instance_variable_get(key)] }
    WebMock.enable!
    WebMock.disable_net_connect!
    stub = WebMock.stub_request(:get, "#{URL}?id=99").to_return(body: "caller stub")
    begin
      assert_replay_error(persisted_case(definition(agent: ->(_) { net_get("id=99"); "ready" })))
      assert_includes registry.request_stubs, stub
      assert_equal "caller stub", net_get("id=99").body
      assert_equal "passed", persisted_case(definition(agent: ->(_) { JSON.parse(net_get.body).fetch("status") })).status
      assert_raises(WebMock::NetConnectNotAllowedError) { net_get }
    ensure
      registry.request_stubs = original_stubs
      original_config.each { |key, value| config.instance_variable_set(key, value) }
      WebMock.disable!
    end
  end

  def test_two_cases_each_get_fresh_repeated_fixtures
    suite = E.define("Repeated shipping", agent: ->(_) { net_get; net_get; "ready" }) do
      evaluate :exact, using: E::Evaluators.exact_match
      2.times do |index|
        question "Track #{index}", expected_answer: "ready" do
          api_interactions do
            2.times do
              expect_request(method: :get, url: URL, query: { id: "42" }).respond_with(json: { status: "ready" })
            end
          end
        end
      end
    end
    cases = E.run(suite).case_results.to_a
    assert_equal ["passed", "passed"], cases.map(&:status)
    cases.each do |record|
      assert_equal ["matched", "matched"], record.response_metadata.fetch("api_replay").fetch("observations").map { |item| item.fetch("status") }
    end
  end

  def test_query_embedded_in_declared_url_is_canonicalized
    suite = E.define("URL query", agent: ->(_) { net_get("tag=b&id=42&tag=a"); "ready" }) do
      evaluate :exact, using: E::Evaluators.exact_match
      question "Track", expected_answer: "ready" do
        api_interactions do
          expect_request(method: :get, url: "#{URL}?tag=a&tag=b&id=42").respond_with(json: { status: "ready" })
        end
      end
    end
    assert_equal "passed", persisted_case(suite).status
  end

  def test_relative_response_file_is_independent_of_working_directory
    Dir.mktmpdir("api-replay-cwd") do |dir|
      suite = Dir.chdir(dir) do
        definition(agent: ->(_) { JSON.parse(net_get.body).fetch("status") }, response: { body_file: BODY_FILE })
      end
      assert_equal "passed", persisted_case(suite).status
    end
  end

  def assert_replay_error(record)
    assert_equal "error", record.status
    assert_equal "RubyLLM::Evaluations::ApiReplay::Mismatch", record.error_details.fetch("class")
    evidence = record.response_metadata.fetch("api_replay")
    assert_equal "failed", evidence.fetch("status")
    assert evidence.key?("expected")
    assert evidence.key?("observations")
    assert evidence.key?("missing")
    assert_equal evidence, JSON.parse(JSON.generate(evidence))
    evidence
  end

  def test_inline_net_http_response_and_evidence_survive_postgres_reload
    response = nil
    suite = definition(agent: ->(_) { response = net_get; JSON.parse(response.body).fetch("status") },
                       response: { status: 201, headers: { "X-Fixture" => "inline" }, json: { status: "ready" } })
    assert_instance_of E::ApiReplay::Definition, suite.cases.first.api_interactions
    record = persisted_case(suite)
    assert_equal "passed", record.status
    assert_equal "201", response.code
    assert_equal "inline", response["X-Fixture"]
    assert_equal "ready", record.output
    evidence = record.response_metadata.fetch("api_replay")
    assert_equal "passed", evidence.fetch("status")
    assert_equal ["matched"], evidence.fetch("observations").map { |item| item.fetch("status") }
    assert_empty evidence.fetch("missing")
  end

  def test_file_response_preserves_exact_bytes_with_faraday
    response = nil
    suite = definition(agent: ->(_) { response = Faraday.get("#{URL}?id=42"); JSON.parse(response.body).fetch("status") },
                       response: { status: 202, headers: { "X-Fixture" => "file" }, body_file: BODY_FILE })
    record = persisted_case(suite)
    assert_equal "passed", record.status
    assert_equal File.binread(File.expand_path(BODY_FILE, __dir__)), response.body
    assert_equal 202, response.status
    assert_equal "file", response.headers["x-fixture"]
    refute_includes JSON.generate(record.response_metadata), __dir__
  end

  def test_wrong_query_is_an_error_even_when_the_agent_rescues_it
    agent = ->(_) do
      begin
        net_get("id=99")
      rescue E::ApiReplay::Mismatch
        # The replay must retain the failed observation, not accept this answer.
      end
      "ready"
    end
    record = persisted_case(definition(agent: agent))
    assert_replay_error(record)
    assert_includes record.error_details.fetch("message"), "99"
    assert_includes record.error_details.fetch("message"), "42"
  end

  def test_missing_exhausted_and_unexpected_requests_are_agent_errors
    agents = [->(_) { "ready" },
              ->(_) { net_get; net_get; "ready" },
              ->(_) { Net::HTTP.get(URI("https://other.example/unexpected")); "ready" }]
    evidence = agents.map { |agent| assert_replay_error(persisted_case(definition(agent: agent))) }
    assert_empty evidence[0].fetch("observations")
    assert_equal 1, evidence[0].fetch("missing").length
    assert_equal ["matched", "unmatched"], evidence[1].fetch("observations").map { |item| item.fetch("status") }
    assert_equal ["unmatched"], evidence[2].fetch("observations").map { |item| item.fetch("status") }
    refute_empty evidence[2].fetch("observations").first.fetch("diff")
  end

  def test_declared_sequence_is_strict_and_repeated_calls_require_repeated_declarations
    build = ->(agent) do
      E.define("Ordered shipping", agent: agent) do
        evaluate :exact, using: E::Evaluators.exact_match
        question "Track", expected_answer: "ready" do
          api_interactions do
            expect_request(method: :get, url: URL, query: { id: "42" }).respond_with(json: { status: "ready" })
            expect_request(method: :get, url: URL, query: { id: "43" }).respond_with(json: { status: "ready" })
          end
        end
      end
    end
    assert_equal "passed", persisted_case(build.call(->(_) { net_get; net_get("id=43"); "ready" })).status
    assert_replay_error(persisted_case(build.call(->(_) { net_get("id=43"); "ready" })))
  end

  def test_request_json_types_headers_and_repeated_query_values
    build = ->(body, header) do
      E.define("Typed shipping", agent: ->(_) do
        client = Faraday.new(request: { params_encoder: Faraday::FlatParamsEncoder })
        client.post("#{URL}?tag=b&id=42&tag=a") do |request|
          request.headers["Content-Type"] = "application/json"
          request.headers["X-Region"] = header
          request.headers["Authorization"] = "Bearer never-persist-this"
          request.body = JSON.generate(body)
        end
        "ready"
      end) do
        evaluate :exact, using: E::Evaluators.exact_match
        question "Track", expected_answer: "ready" do
          api_interactions do
            expect_request(method: :post, url: URL, query: { id: "42", tag: ["a", "b"] },
                           json: { count: 1, enabled: false }, headers: { "X-Region" => "eu" })
              .respond_with(json: { status: "ready" })
          end
        end
      end
    end
    good = persisted_case(build.call({ count: 1, enabled: false }, "eu"))
    assert_equal "passed", good.status
    refute_includes JSON.generate(good.response_metadata), "never-persist-this"
    [{ count: "1", enabled: false }, { count: 1, enabled: nil }].each do |body|
      record = persisted_case(build.call(body, "eu"))
      assert_replay_error(record)
      refute_includes JSON.generate(record.response_metadata), "never-persist-this"
      refute_includes JSON.generate(record.error_details), "never-persist-this"
    end
    assert_replay_error(persisted_case(build.call({ count: 1, enabled: false }, "us")))
  end

  def test_undeclared_request_body_is_not_ignored
    agent = ->(_) do
      request = Net::HTTP::Get.new(URI("#{URL}?id=42"))
      request.body = "unexpected"
      Net::HTTP.start("shipping.example", 443, use_ssl: true) { |http| http.request(request) }
      "ready"
    end
    assert_replay_error(persisted_case(definition(agent: agent)))
  end

  def test_cases_and_runs_do_not_share_consumed_interactions
    suite = definition(agent: ->(_) { JSON.parse(net_get.body).fetch("status") })
    2.times { assert_equal "passed", persisted_case(suite).status }
    failing = definition(agent: ->(_) { "ready" })
    assert_replay_error(persisted_case(failing))
    assert_equal "passed", persisted_case(suite).status
  end

  def test_exact_allow_host_does_not_bypass_a_declared_fixture
    suite = definition(agent: ->(_) { JSON.parse(net_get.body).fetch("status") }, allow_hosts: ["shipping.example"])
    assert_equal "passed", persisted_case(suite).status
    wrong = definition(agent: ->(_) { net_get("id=99"); "ready" }, allow_hosts: ["shipping.example"])
    assert_replay_error(persisted_case(wrong))
  end

  def test_invalid_response_files_and_exclusive_sources_fail_before_agent_execution
    calls = 0
    agent = ->(_) { calls += 1; "ready" }
    [{}, { json: nil, body_file: BODY_FILE }, { body_file: "missing-api-replay.json" }].each do |response|
      assert_raises(E::DefinitionError) { E.run(definition(agent: agent, response: response)) }
    end
    Dir.mktmpdir("api-replay") do |dir|
      path = File.join(dir, "invalid.json")
      File.binwrite(path, "not JSON")
      assert_raises(E::DefinitionError) { E.run(definition(agent: agent, response: { body_file: path })) }
      File.binwrite(path, "{\"invalid\":\"\xFF\"}")
      assert_raises(E::DefinitionError) { E.run(definition(agent: agent, response: { body_file: path })) }
    end
    assert_equal 0, calls
  end

  def test_inline_null_is_a_valid_response_source
    suite = definition(agent: ->(_) { assert_equal "null", net_get.body; "ready" }, response: { json: nil })
    assert_equal "passed", persisted_case(suite).status
  end

  def test_file_bytes_change_fingerprints_and_prevent_incompatible_baselines
    Dir.mktmpdir("api-replay") do |dir|
      path = File.join(dir, "response.json")
      File.write(path, '{"status":"ready"}')
      agent = ->(_) { JSON.parse(net_get.body).fetch("status") }
      first_suite = definition(agent: agent, response: { body_file: path })
      baseline = E.run(first_suite)
      File.write(path, "{\n  \"status\": \"ready\"\n}\n")
      # Already defined fixtures remain immutable even after the source changes.
      assert_equal baseline.suite_digest, E.run(first_suite).suite_digest
      current = E.run(definition(agent: agent, response: { body_file: path }))
      refute_equal baseline.suite_digest, current.suite_digest
      assert_nil current.previous
      assert_raises(ArgumentError) { E::Report.new(current, baseline: baseline) }
    end
  end
end
