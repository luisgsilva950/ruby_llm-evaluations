# frozen_string_literal: true

# Offline consumer example, not proof of model reasoning. Requires optional ruby_llm.
require "ruby_llm"
require "ruby_llm/evaluations"

class RenderReturnPolicy < RubyLLM::Tool
  include RubyLLM::Evaluations::ResponseComponentTool
  response_component protocol: "a2ui", version: "0.8"
  description "Render a return policy surface"
  param :days, type: :integer, desc: "Return window in days"

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

RubyLLM::Evaluations.define("A2UI return policy", agent: agent, agent_name: "ReturnPolicyAgent", version: "1") do
  evaluate :text, using: RubyLLM::Evaluations::Evaluators.exact_match
  evaluate :a2ui, using: RubyLLM::Evaluations::Evaluators.response_components(protocol: "a2ui", version: "0.8") { |components, context|
    # Application-specific contract for this surface; not a complete A2UI schema validator.
    expected = [
      { "surfaceUpdate" => { "surfaceId" => "returns", "components" => [
        { "id" => "root", "component" => { "Text" => { "text" => { "literalString" => context.expected_answer } } } }
      ] } },
      { "beginRendering" => { "surfaceId" => "returns", "root" => "root" } }
    ]
    components.size == 1 && components.first.fetch("payload").lines.map { |line| JSON.parse(line) } == expected
  }
  question "Show the return policy", expected_answer: "Returns within 30 days",
           minimum_scores: { text: 1.0, a2ui: 1.0 }, metadata: { protocol: "a2ui", protocol_version: "0.8" }
end
