# frozen_string_literal: true
require "minitest/autorun"
require_relative "postgres_helper"
require_relative "../lib/ruby_llm/evaluations"

class SemanticEvaluationTest < Minitest::Test
  E = RubyLLM::Evaluations

  def context(reference = "Returns are accepted within thirty days.")
    E::TestCase.new(input: "How long do I have to return an item?", expected: reference)
  end

  def test_paraphrase_uses_configured_judgment_not_exact_matching
    judge = ->(_prompt) { E::Response.new(output: { score: 0.95, reason: "Equivalent return window expressed differently." }) }
    output = "You have a month (30 days) to send it back."
    refute E::Evaluators.exact_match.call(output, context)
    result = E::Evaluators.semantic_accuracy(judge: judge).call(output, context)
    assert_equal 0.95, result.score
    assert_equal "Equivalent return window expressed differently.", result.reason
  end

  def test_relevance_can_be_high_while_accuracy_is_low
    output = "You have 300 days to return it."
    accuracy = E::Evaluators.semantic_accuracy(judge: ->(_) { '{"score":0.1,"reason":"Contradicts the reference window."}' })
    relevance = E::Evaluators.answer_relevancy(judge: ->(_) { '{"score":1,"reason":"Directly answers the return-window question."}' })
    assert_equal 0.1, accuracy.call(output, context).score
    assert_equal 1, relevance.call(output, context(nil)).score
    irrelevant = E::Evaluators.answer_relevancy(judge: ->(_) { { score: 0, reason: "Weather facts do not address returns." } })
    assert_equal 0, irrelevant.call("Water freezes at zero Celsius.", context).score
  end

  def test_missing_reference_does_not_call_judge
    evaluator = E::Evaluators.semantic_accuracy(judge: ->(_) { flunk "judge must not be called" })
    [nil, "", "  ", [], {}].each do |reference|
      assert_raises(ArgumentError) { evaluator.call("answer", context(reference)) }
    end
  end

  def test_invalid_judge_results_are_errors
    ["not JSON", "[]", "null", {}, { score: true, reason: "yes" },
     { score: 1.1, reason: "yes" }, { score: Float::NAN, reason: "yes" },
     { score: 1, reason: " " }, { score: "1", reason: "yes" }].each do |answer|
      evaluator = E::Evaluators.answer_relevancy(judge: ->(_) { answer })
      assert_raises(ArgumentError, JSON::ParserError) { evaluator.call("answer", context) }
    end
  end

  def test_provider_failure_is_not_converted_to_assessment
    evaluator = E::Evaluators.semantic_accuracy(judge: ->(_) { raise "judge offline" })
    error = assert_raises(RuntimeError) { evaluator.call("answer", context) }
    assert_equal "judge offline", error.message
  end
  def test_runner_persists_judge_errors_without_skipping_other_checks
    judgments = [{ score: 0.95, reason: "Accurate paraphrase." }, "malformed"]
    judge = ->(_) { judgments.shift }
    suite = E.define("semantic integration", agent: ->(_) { "You have 30 days." }) do
      evaluate :accuracy, using: E::Evaluators.semantic_accuracy(judge: judge), threshold: 0.9
      evaluate :relevance, using: E::Evaluators.answer_relevancy(judge: ->(_) { { score: 1, reason: "On topic." } })
      test "paraphrase", input: "Return window?", expected: "Within thirty days."
      test "bad judgment", input: "Return window?", expected: "Within thirty days."
      test "no reference", input: "Return window?"
    end
    sandbox = PostgresSandbox.new
    begin
      store = E::Store.new(sandbox.database_url)
      begin
        run = E::Runner.new(store: store).run(suite)
        assert_equal %w[passed error error], run["cases"].map { |item| item["status"] }
        assert_equal run, store.find(run["id"])
        assert_equal 2, run["cases"][1]["evaluations"].size
      ensure
        store.close
      end
    ensure
      sandbox.close
    end
  end
end