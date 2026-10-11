# frozen_string_literal: true

require "ruby_llm/evaluations"

# Offline, instrumented retrieval agent. No provider calls or credentials required.
# AGENT_REVISION=regressed introduces a wrong policy answer AND wrong lookup arguments.
policies = {
  "How long is the return window?" => "Returns are accepted within 30 days.",
  "How long does shipping take?" => "Standard shipping takes 3 to 5 business days.",
  "Can I track my order?" => "Use the tracking link in your shipping confirmation email.",
  "Do you support international orders?" => "We ship to the US and Canada.",
  "How do I contact support?" => "Email support@example.com.",
  "Can you give me a discount?" => "I cannot promise discounts. Please contact support."
}.freeze

agent = lambda do |input|
  regressed = ENV["AGENT_REVISION"] == "regressed" && input == "How long is the return window?"
  lookup_question = regressed ? "How long does shipping take?" : input
  answer = policies.fetch(lookup_question)
  answer = "Returns are accepted within 7 days." if regressed
  RubyLLM::Evaluations::Response.new(
    output: answer,
    actions: [{ group: "policies", name: "lookup_policy", arguments: { question: lookup_question } }]
  )
end

RubyLLM::Evaluations.define("support policies", agent: agent, agent_name: "SupportAgent", version: "1") do
  evaluate :policy_accuracy, using: RubyLLM::Evaluations::Evaluators.exact_match
  evaluate :action_group, using: RubyLLM::Evaluations::Evaluators.action_group
  policies.each do |question, answer|
    test question, input: question, expected: answer,
         expected_actions: [{ group: "policies", name: "lookup_policy", arguments: { question: question } }]
  end
end
