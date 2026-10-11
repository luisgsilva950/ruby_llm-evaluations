# frozen_string_literal: true
require "minitest/autorun"
require_relative "postgres_helper"
require_relative "../lib/ruby_llm/evaluations"
begin
  require "ruby_llm"
rescue LoadError
  # Optional integration: deterministic core tests do not require the provider gem.
end

class RubyLLMAdapterTest < Minitest::Test
  E = RubyLLM::Evaluations

  def setup
    skip "Install optional ruby_llm to exercise real message structures" unless defined?(RubyLLM::Message)
  end

  def llm_message(content: "answer", **options)
    RubyLLM::Message.new({ role: :assistant, content: content, model_id: "local-fixture" }.merge(options))
  end

  def test_normalization_preserves_usage_and_model_without_claiming_full_trace
    result = E::Response.normalize(llm_message(input_tokens: 12, output_tokens: 4, cached_tokens: 3))
    assert_equal "answer", result.output
    assert_equal 12, result.input_tokens
    assert_equal 4, result.output_tokens
    assert_equal "local-fixture", result.metadata["model_id"]
    assert_equal 3, result.metadata["cached_tokens"]
    assert_nil result.actions
    assert_equal [], E::Response.new(output: "answer", actions: []).actions
  end

  def test_multiple_turns_order_arguments_totals_and_fresh_state
    chats = []
    factory = lambda do
      # Real Chat/message APIs, with only the network completion boundary replaced.
      chat = RubyLLM::Chat.allocate
      chat.instance_variable_set(:@messages, [])
      turns = [llm_message(content: nil, input_tokens: 10, output_tokens: 2,
                       tool_calls: { "a" => RubyLLM::ToolCall.new(id: "a", name: "lookup", arguments: { sku: "book" }),
                                     "b" => RubyLLM::ToolCall.new(id: "b", name: "audit", arguments: {}) }),
               llm_message(content: nil, input_tokens: 20, output_tokens: 3,
                       tool_calls: { "c" => RubyLLM::ToolCall.new(id: "c", name: "lookup", arguments: { sku: "pen" }) }),
               llm_message(input_tokens: 30, output_tokens: 5)]
      chat.define_singleton_method(:ask) do |input|
        messages << RubyLLM::Message.new(role: :user, content: input)
        messages.concat(turns)
        turns.last
      end
      chats << chat
      chat
    end
    agent = E::Adapters.ruby_llm_chat(action_groups: { lookup: "catalog" }, &factory)
    first = agent.call("first")
    second = agent.call("second")
    assert_equal %w[lookup audit lookup], first.actions.map { |a| a["name"] }
    assert_equal ["catalog", nil, "catalog"], first.actions.map { |a| a["group"] }
    assert_equal({ "sku" => "pen" }, first.actions.last["arguments"])
    assert_equal 60, first.input_tokens
    assert_equal 10, first.output_tokens
    assert_equal first.actions, second.actions
    refute_same chats[0], chats[1]
    assert_equal [4, 4], chats.map { |chat| chat.messages.size }
    suite = E.define("traced chat integration", agent: agent) do
      evaluate :actions, using: E::Evaluators.action_group
      test "first", input: "first", expected_actions: first.actions.reject { |action| action["group"].nil? }
      test "second", input: "second", expected_actions: first.actions.reject { |action| action["group"].nil? }
    end
    sandbox = PostgresSandbox.new
    begin
      store = E::Store.new(sandbox.database_url)
      begin
        run = E::Runner.new(store: store).run(suite)
        assert_equal %w[failed failed], run["cases"].map { |item| item["status"] }
        assert_equal first.actions, run["cases"][0]["actions"]
        assert_equal 60, run["cases"][1]["input_tokens"]
        assert_equal run, store.find(run["id"])
      ensure
        store.close
      end
    ensure
      sandbox.close
    end
  end

  def test_partial_unknown_usage_is_not_reported_as_zero_or_partial_total
    turns = [llm_message(input_tokens: 10), llm_message(output_tokens: 2)]
    chat = Struct.new(:messages) do
      def ask(_input) = messages.last
    end.new(turns)
    result = E::Adapters.ruby_llm_chat { chat }.call("question")
    assert_nil result.input_tokens
    assert_nil result.output_tokens
    assert_equal [], result.actions
  end
end