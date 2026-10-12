# frozen_string_literal: true

require "minitest/autorun"
require "ruby_llm"
require_relative "../../lib/ruby_llm/evaluations"
require_relative "../postgres_helper"
require_relative "../support/local_llm_server"

class ResponseComponentsTest < Minitest::Test
  E = RubyLLM::Evaluations

  class RenderPolicy < RubyLLM::Tool
    include E::ResponseComponentTool
    response_component protocol: "a2ui", version: "0.8"
    description "Render the return policy"
    param :product, desc: "Product name"
    def name = "return_policy"
    def initialize(days: 30) = @days = days
    def execute(product:)
      [JSON.generate(surfaceUpdate: { surfaceId: "policy", components: [
        { id: "root", component: { Text: { text: { literalString: "#{product}: #{@days} days" } } } }
      ] }), JSON.generate(beginRendering: { surfaceId: "policy", root: "root" })].join("\n")
    end
  end

  class HaltPolicy < RenderPolicy
    def execute(product:) = halt(super)
  end

  class MutableTool < RubyLLM::Tool
    include E::ResponseComponentTool
    response_component protocol: "card"
    attr_accessor :payload
    def execute(label:)
      label.replace("mutated argument")
      payload
    end
  end

  def setup
    @sandbox = PostgresSandbox.new
  end

  def teardown
    @server&.close
    @sandbox&.close
  end

  def ui_check
    E::Evaluators.response_components(protocol: "a2ui", version: "0.8") do |components, context|
      components.size == 1 && components.first.fetch("payload").lines.map { |line| JSON.parse(line) } == [
        { "surfaceUpdate" => { "surfaceId" => "policy", "components" => [
          { "id" => "root", "component" => { "Text" => { "text" => { "literalString" => context.metadata.fetch(:label) } } } }
        ] } },
        { "beginRendering" => { "surfaceId" => "policy", "root" => "root" } }
      ]
    end
  end

  def test_real_ruby_llm_tool_results_callbacks_case_isolation_and_durable_regression
    @server = LocalLLMServer.new
    config = RubyLLM::Configuration.new
    config.openai_api_key = "local-fixture-only"
    config.openai_api_base = @server.base_url
    config.max_retries = 0
    config.http_proxy = nil
    context = RubyLLM::Context.new(config)
    days = 30
    callbacks = []
    chats = []
    agent = E::Adapters.ruby_llm_chat do
      chat = context.chat(model: "fixture-agent", provider: :openai, assume_model_exists: true)
        .with_tools(RenderPolicy.new(days: days))
      chat.on_tool_call { |call| callbacks << [:call, call.name] }
      chat.on_tool_result { |result| callbacks << [:result, result] }
      chats << chat
      chat
    end
    check = ui_check
    definition = E.define("Structured policy", agent: agent, agent_name: "SupportAgent") do
      evaluate :text, using: E::Evaluators.exact_match
      evaluate :ui, using: check
      %w[first second].each do |input|
        question input, expected_answer: LocalLLMServer::ANSWER, metadata: { label: "book: 30 days" }
      end
    end
    baseline = E.run(definition)
    assert_equal %w[passed passed], baseline.case_results.map(&:status)
    baseline.case_results.each do |result|
      assert_equal [{ "protocol" => "a2ui", "version" => "0.8", "tool_name" => "return_policy",
        "arguments" => { "product" => "book" }, "payload" => RenderPolicy.new.execute(product: "book") }], result.components
    end
    assert_equal RenderPolicy.new.execute(product: "book"), @server.requests.last["messages"].last["content"]
    assert_equal [:call, :result, :call, :result], callbacks.map(&:first)
    refute_same chats.first, chats.last

    days = 7
    current = E.run(definition)
    assert_equal %w[failed failed], current.case_results.map(&:status)
    current.case_results.each do |result|
      assert result.metric_results.find { |metric| metric.name == "text" }.passed
      refute result.metric_results.find { |metric| metric.name == "ui" }.passed
    end
    reopened = E::Run.with_results.find(current.id)
    assert_equal current.snapshot, reopened.snapshot
    report = E::Report.new(reopened, baseline: reopened.previous)
    assert report.comparison.fetch("regressed")
    assert_equal ["ui"], report.comparison.fetch("regressions").map { |change| change.fetch("evaluator") }.uniq
    assert_equal reopened.case_results.first.components, JSON.parse(report.to_json).fetch("cases").first.fetch("components")
    assert_includes report.to_html, "book: 7 days"
    assert_includes report.to_markdown, "book: 7 days"
    assert_includes report.to_text, "book: 7 days"
  end

  def test_missing_empty_wrong_protocol_and_wrong_version_never_pass_an_empty_all_check
    inputs = [nil, [], [{ protocol: "card", payload: {} }], [{ protocol: "a2ui", version: "0.9", payload: {} }]]
    checked = []
    check = E::Evaluators.response_components(protocol: "a2ui", version: "0.8") do |components, _context|
      checked << components
      components.all? { true }
    end
    agent = ->(index) { E::Response.new(output: "correct text", components: inputs.fetch(index)) }
    definition = E.define("Missing UI", agent: agent) do
      evaluate :text, using: E::Evaluators.exact_match
      evaluate :ui, using: check
      inputs.each_index { |index| question index, expected_answer: "correct text", name: "UI #{index}" }
    end
    run = E.run(definition)
    assert_equal %w[failed failed failed failed], run.case_results.map(&:status)
    assert run.case_results.all? { |result| result.metric_results.find { |metric| metric.name == "text" }.passed }
    assert_empty checked
  end

  def test_callable_tools_snapshot_mutable_results_and_arguments_without_changing_returns
    tool = MutableTool.new
    tool.payload = { "label" => +"first" }
    observed = []
    agent = lambda do |_input|
      observed << tool.call(label: +"requested")
      tool.payload["label"].replace("second")
      observed << tool.call(label: +"next")
      "ok"
    end
    definition = E.define("Mutable UI", agent: agent) do
      evaluate(:ui) { |_output, context| context.response.components.map { |item| item.fetch("payload").fetch("label") } == %w[first second] }
      question "render"
    end
    run = E.run(definition)
    assert_equal "passed", run.case_results.first.status
    assert_same tool.payload, observed.first
    assert_same tool.payload, observed.last
    assert_equal %w[requested next], run.case_results.first.components.map { |item| item.fetch("arguments").fetch("label") }
    assert_same tool.payload, tool.call(label: +"outside evaluation")
  end

  def test_explicit_nontext_components_errors_and_later_cases
    values = [Object.new, [{ protocol: "a2ui", payload: Float::NAN }], [{ protocol: "a2ui", payload: { "text" => "雪<script>alert(1)</script>" } }]]
    agent = ->(index) { E::Response.new(output: nil, components: values.fetch(index)) }
    check = E::Evaluators.response_components(protocol: "a2ui") { |items, _context| items.first.fetch("payload").fetch("text").start_with?("雪") }
    definition = E.define("Nontext evidence", agent: agent) do
      evaluate :ui, using: check
      values.each_index { |index| question index, name: "component #{index}" }
    end
    run = E.run(definition)
    assert_equal %w[error error passed], run.case_results.map(&:status)
    assert_nil run.case_results.last.output
    html = E::Report.new(run).to_html
    refute_includes html, "<script>alert(1)</script>"
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    status, _headers, body = E::Dashboard.new.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/runs/#{run.id}")
    assert_equal 200, status
    refute_includes body.join, "<script>alert(1)</script>"
    assert_includes body.join, "&lt;script&gt;alert(1)&lt;/script&gt;"
  end

  def test_nested_fibers_and_exceptions_do_not_leak_tool_results
    tool = RenderPolicy.new
    outer = E::ResponseComponents.capture do
      tool.call(product: "outer")
      assert_raises(RuntimeError) do
        E::ResponseComponents.capture { tool.call(product: "discarded"); raise "agent failed" }
      end
      inner = Fiber.new { E::ResponseComponents.capture { tool.call(product: "fiber") } }.resume
      assert_equal ["fiber"], inner.last.map { |item| item.fetch("arguments").fetch("product") }
      tool.call(product: "after")
    end
    assert_equal %w[outer after], outer.last.map { |item| item.fetch("arguments").fetch("product") }
    fresh = E::ResponseComponents.capture { tool.call(product: "fresh") }
    assert_equal ["fresh"], fresh.last.map { |item| item.fetch("arguments").fetch("product") }
  end

  def test_inherited_markers_preserve_halt_behavior
    result, components = E::ResponseComponents.capture { HaltPolicy.new.call(product: "book") }
    assert_instance_of RubyLLM::Tool::Halt, result
    assert_equal RenderPolicy.new.execute(product: "book"), result.content
    assert_equal result.content, components.first.fetch("payload")
    assert_equal "0.8", components.first.fetch("version")
  end
end
