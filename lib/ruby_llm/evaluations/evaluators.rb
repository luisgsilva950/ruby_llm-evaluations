# frozen_string_literal: true

require "json"

module RubyLLM
  module Evaluations
    Assessment = Struct.new(:score, :reason, keyword_init: true)

    module Evaluators
      module_function

      def exact_match
        ->(output, context) { output == context.expected_answer }
      end

      def contains
        lambda do |output, context|
          unless output.is_a?(String) && context.expected_answer.is_a?(String)
            raise ArgumentError, "contains requires string output and expected_answer"
          end
          output.include?(context.expected_answer)
        end
      end

      def matches(pattern)
        raise ArgumentError, "pattern must be a Regexp" unless pattern.is_a?(Regexp)
        ->(output, _context) { pattern.match?(output.to_s) }
      end

      def valid_json
        lambda do |output, _context|
          JSON.parse(output)
          true
        rescue JSON::ParserError, TypeError
          false
        end
      end

      def response_components(protocol:, version: nil, &check)
        ResponseComponents.validate_label!(protocol, "component protocol")
        ResponseComponents.validate_label!(version, "component version") unless version.nil?
        raise ArgumentError, "provide a response component check block" unless check
        lambda do |_output, context|
          components = context.response.components
          if components.nil?
            next Assessment.new(score: false, reason: "Response component instrumentation missing")
          end
          matching = components.select { |item| item["protocol"] == protocol }
          if matching.empty?
            next Assessment.new(score: false, reason: "No #{protocol} response components")
          end
          if version && matching.any? { |item| item["version"] != version }
            next Assessment.new(score: false, reason: "Unexpected #{protocol} protocol version")
          end
          check.call(matching, context)
        end
      end

      def semantic_accuracy
        JudgeMetric.new(reference: true, rubric: <<~RUBRIC)
          Score factual semantic agreement with the expected reference, not lexical overlap.
          Accept accurate paraphrases and equivalent meaning. Penalize omitted essential facts,
          unsupported factual additions and contradictions. 1 means fully supported agreement;
          0 means no correct essential meaning or a fundamentally contradictory answer;
          intermediate scores reflect the proportion and importance of factual errors.
        RUBRIC
      end

      def answer_relevancy
        llm_judge(rubric: <<~RUBRIC)
          Score how directly and completely the answer addresses the user intent in question.
          Judge relevancy independently of factual accuracy: a factually wrong but on-topic
          answer can be relevant; a true but unrelated answer is irrelevant. Ignore expected_answer
          as a factual reference. Penalize tangents, evasion and missing requested components.
          1 means fully responsive and focused, 0 means entirely unrelated or nonresponsive;
          intermediate scores reflect partial fulfillment of the request.
        RUBRIC
      end

      def llm_judge(rubric:)
        JudgeMetric.new(rubric: rubric)
      end
    end
  end
end
