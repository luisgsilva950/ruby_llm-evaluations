# frozen_string_literal: true

require "ruby_llm/evaluations"

# Offline deterministic demo, NOT semantic judging. No provider calls or credentials.
# The recorded action is the actual lookup executed by this local agent.
class OfflineSupportAgent
  def call(question)
    regressed = ENV["AGENT_REVISION"] == "regressed" && question == "How long do I have to return an item?"
    lookup_question = regressed ? "How long does shipping take?" : question
    answer = lookup_answer(lookup_question)
    answer = "You can return it within 7 days." if regressed
    RubyLLM::Evaluations::Response.new(
      output: answer,
      actions: [{ group: "support", name: "lookup_answer", arguments: { question: lookup_question } }]
    )
  end

  private

  def lookup_answer(question)
    case question
    when "How long do I have to return an item?" then "You can return it within 30 days."
    when "How long does shipping take?" then "Standard shipping takes 3 to 5 business days."
    when "Can I track my order?" then "Use the tracking link in your shipping confirmation email."
    else raise ArgumentError, "unknown support question"
    end
  end
end

RubyLLM::Evaluations.define("Customer support (offline exact match)", agent: OfflineSupportAgent.new,
                            agent_name: "SupportAgent", version: "1") do
  evaluate :exact_match, using: RubyLLM::Evaluations::Evaluators.exact_match
  evaluate :action_group, using: RubyLLM::Evaluations::Evaluators.action_group
  # minimum_scores applies absolute inclusive thresholds on every run, including the first.
  # Previous-run regression comparison is separate and requires a compatible definition.

  question "How long do I have to return an item?",
           expected_answer: "You can return it within 30 days.",
           minimum_scores: { exact_match: 1.0, action_group: 1.0 },
           metadata: { important_facts: ["The return deadline is 30 days."] },
           expected_actions: [{ group: "support", name: "lookup_answer",
                                arguments: { question: "How long do I have to return an item?" } }]
  question "How long does shipping take?",
           expected_answer: "Standard shipping takes 3 to 5 business days.",
           expected_actions: [{ group: "support", name: "lookup_answer",
                                arguments: { question: "How long does shipping take?" } }]
  question "Can I track my order?",
           expected_answer: "Use the tracking link in your shipping confirmation email.",
           expected_actions: [{ group: "support", name: "lookup_answer",
                                arguments: { question: "Can I track my order?" } }]
end
