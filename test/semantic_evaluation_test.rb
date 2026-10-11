# frozen_string_literal: true
require "minitest/autorun"
require "ruby_llm"
require_relative "../lib/ruby_llm/evaluations"

class SemanticEvaluationTest < Minitest::Test
  E = RubyLLM::Evaluations
  class NeverAskedJudge < RubyLLM::Agent
    def initialize(*)
      raise "Judge must not be instantiated for an invalid reference"
    end
  end

  def test_missing_reference_is_rejected_before_creating_a_judge
    [nil, "", "  ", [], {}].each do |reference|
      question = E::Question.new(question: "Return deadline?", expected_answer: reference, metadata: {})
      context = E::Context.new(question, E::Response.new(output: "30 days"), judge: NeverAskedJudge)
      assert_raises(ArgumentError) { E::Evaluators.semantic_accuracy.call("30 days", context) }
    end
  end

  def test_judge_must_be_a_rubyllm_agent_class
    [->(_) { "answer" }, Object.new, String].each do |judge|
      assert_raises(E::DefinitionError) { E::Suite.new("invalid judge", agent: ->(q) { q }, judge: judge) }
    end
  end

  def test_judged_and_unjudged_definitions_do_not_share_baselines
    build = ->(judge) do
      E.define("same questions", agent: ->(_) { "30 days" }, judge: judge) do
        question "Return deadline?", expected_answer: "30 days"
      end
    end
    refute_equal build.call(nil).digest, build.call(NeverAskedJudge).digest
  end
end
