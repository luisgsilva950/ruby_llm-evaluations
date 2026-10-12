# frozen_string_literal: true

require "net/http"
require "json"
require "ruby_llm/evaluations"

# Real HTTP request construction and parsing; the framework supplies the response.
agent = lambda do |question|
  order_id = ENV["AGENT_REVISION"] == "regressed" ? "99" : question.fetch(:order_id)
  uri = URI("https://shipping.example/orders/#{order_id}")
  uri.query = URI.encode_www_form(include_events: "true")
  response = Net::HTTP.get_response(uri)
  data = JSON.parse(response.body)
  RubyLLM::Evaluations::Response.new(
    output: data.fetch("status"),
    actions: [{ group: "shipping", name: "lookup_order", arguments: { order_id: order_id } }]
  )
end

RubyLLM::Evaluations.define("Shipping API replay", agent: agent, agent_name: "ShippingAgent") do
  evaluate :exact_match, using: RubyLLM::Evaluations::Evaluators.exact_match
  question({ order_id: "42" }, name: "File-backed order", expected_answer: "in_transit",
           minimum_scores: { exact_match: 1.0, action_group: 1.0 },
           expected_actions: [{ group: "shipping", name: "lookup_order", arguments: { order_id: "42" } }]) do
    api_interactions do
      expect_request(method: :get, url: "https://shipping.example/orders/42",
                     query: { include_events: "true" }).respond_with(
        body_file: "fixtures/order-42.json"
      )
    end
  end

  question({ order_id: "43" }, name: "Inline order", expected_answer: "delivered") do
    api_interactions do
      expect_request(method: :get, url: "https://shipping.example/orders/43",
                     query: { include_events: "true" }).respond_with(
        json: { id: "43", status: "delivered" }
      )
    end
  end
end
