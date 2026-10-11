# frozen_string_literal: true

require "ruby_llm"
require "ruby_llm/evaluations"

RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

agent = RubyLLM::Evaluations::Adapters.ruby_llm_chat do
  RubyLLM.chat(model: ENV.fetch("EVAL_MODEL", "gpt-4.1-mini"))
         .with_instructions("Answer each question concisely. Follow the requested output format.")
end

RubyLLM::Evaluations.define("general knowledge", agent: agent, agent_name: "KnowledgeAgent") do
  evaluate :correctness, using: RubyLLM::Evaluations::Evaluators.contains
  test "France capital", input: "What is the capital of France?", expected: "Paris"
  test "basic arithmetic", input: "What is 6 multiplied by 7? Reply with digits only.", expected: "42"
end
