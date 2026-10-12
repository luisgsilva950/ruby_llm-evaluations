# frozen_string_literal: true

require "ruby_llm"
require "ruby_llm/evaluations"
require "net/http"
require "json"

module ContextBloatExample
  E = RubyLLM::Evaluations
  MAX_TOOL_RESULT_BYTES = 4_096

  class ReturnPolicy < RubyLLM::Tool
    description "Read the current product return deadline"
    param :product, desc: "Product name"
    attr_reader :api_response_bytes

    def initialize(raw: false)
      super()
      @raw = raw
    end

    def name = "return_policy"

    def execute(product:)
      uri = URI("https://policy.example/returns")
      uri.query = URI.encode_www_form(product: product)
      body = Net::HTTP.get_response(uri).body
      @api_response_bytes = body.bytesize
      return body if @raw

      data = JSON.parse(body)
      # Preserve the relevant facts at the end, rather than truncating the beginning.
      JSON.generate(product: data.fetch("product"), return_days: data.fetch("return_days"))
    end
  end

  def self.suite(context:, model:, allow_host:, raw: false, expected_answer: "30")
    agent = lambda do |question|
      tool = ReturnPolicy.new(raw: raw)
      chat = context.chat(model: model, provider: :openai, assume_model_exists: true)
        .with_instructions("Use return_policy for the book. Reply with only the numeric return deadline.")
        .with_tools(tool)
      adapter = E::Adapters.ruby_llm_chat(action_groups: { return_policy: "returns" }) { chat }
      response = adapter.call(question)
      tool_bytes = chat.messages.select { |message| message.role == :tool }.map { |message| message.content.to_s.bytesize }
      E::Response.new(output: response.output, actions: response.actions, components: response.components,
                     input_tokens: response.input_tokens, output_tokens: response.output_tokens, cost: response.cost,
                     metadata: response.metadata.merge("tool_result_bytes" => tool_bytes,
                                                       "api_response_bytes" => tool.api_response_bytes))
    end

    E.define("Large tool result context budget", agent: agent, agent_name: "ReturnPolicyAgent") do
      evaluate :exact_match, using: E::Evaluators.exact_match
      evaluate :tool_result_budget do |_output, context|
        sizes = context.response.metadata.fetch("tool_result_bytes")
        raise E::Error, "tool-result instrumentation missing" if sizes.empty?
        sizes.all? { |bytes| bytes <= context.metadata.fetch(:max_tool_result_bytes) }
      end
      question "What is the return deadline for my book?", expected_answer: expected_answer,
               minimum_scores: { exact_match: 1.0, action_group: 1.0, tool_result_budget: 1.0 },
               metadata: { max_tool_result_bytes: MAX_TOOL_RESULT_BYTES },
               expected_actions: [{ group: "returns", name: "return_policy", arguments: { product: "book" } }] do
        api_interactions(allow_hosts: [allow_host]) do
          expect_request(method: :get, url: "https://policy.example/returns", query: { product: "book" })
            .respond_with(body_file: "fixtures/large_return_policy.json")
        end
      end
    end
  end
end

# Loading this file for a local transport test does not configure or call a provider.
if ENV["RUN_CONTEXT_BLOAT_EVAL"] == "1"
  context = RubyLLM.context { |config| config.openai_api_key = ENV.fetch("OPENAI_API_KEY") }
  ContextBloatExample.suite(context: context, model: ENV.fetch("OPENAI_MODEL", "gpt-4.1-mini"),
                           allow_host: "api.openai.com", raw: ENV["AGENT_REVISION"] == "regressed")
end
