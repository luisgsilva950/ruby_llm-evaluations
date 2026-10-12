# frozen_string_literal: true

# Offline consumer example, not proof of model reasoning. Requires ruby_llm 1.x (1.14.1+).
require "ruby_llm"
require "ruby_llm/evaluations"

class RenderReturnPolicy < RubyLLM::Tool
  prepend RubyLLM::Evaluations::ResponseComponentTool
  description "Render a return policy surface"
  param :days, type: :integer, desc: "Return window in days"

  def response_component
    { protocol: "a2ui", version: "0.8" }
  end

  def execute(days:)
    [
      JSON.generate(surfaceUpdate: { surfaceId: "returns", components: [
        { id: "root", component: { Text: { text: { literalString: "Returns within #{days} days" } } } }
      ] }),
      JSON.generate(beginRendering: { surfaceId: "returns", root: "root" })
    ].join("\n")
  end
end

agent = lambda do |_question|
  unless ENV["AGENT_REVISION"] == "missing_ui"
    days = ENV["AGENT_REVISION"] == "regressed" ? 7 : 30
    RenderReturnPolicy.new.call(days: days)
  end
  "Returns within 30 days" # Correct text alone must not conceal incorrect/missing UI.
end

# Expected UI is question data, independent of the tool implementation.
expected_ui_messages = [
  { "surfaceUpdate" => { "surfaceId" => "returns", "components" => [
    { "id" => "root", "component" => { "Text" => { "text" => { "literalString" => "Returns within 30 days" } } } }
  ] } },
  { "beginRendering" => { "surfaceId" => "returns", "root" => "root" } }
]

# Application-specific contract, not a complete A2UI schema validator.
ui_check = RubyLLM::Evaluations::Evaluators.response_components(protocol: "a2ui", version: "0.8") do |components, context|
  next false unless components.one?

  actual_messages = components.first.fetch("payload").lines.map { |line| JSON.parse(line) }
  actual_messages == context.metadata.fetch(:expected_ui_messages)
end

RubyLLM::Evaluations.define("A2UI return policy", agent: agent, agent_name: "ReturnPolicyAgent", version: "1") do
  evaluate :text, using: RubyLLM::Evaluations::Evaluators.exact_match
  evaluate :a2ui, using: ui_check
  question "Show the return policy",
           expected_answer: "Returns within 30 days",
           minimum_scores: { text: 1.0, a2ui: 1.0 },
           metadata: { protocol: "a2ui", protocol_version: "0.8", expected_ui_messages: expected_ui_messages }
end
