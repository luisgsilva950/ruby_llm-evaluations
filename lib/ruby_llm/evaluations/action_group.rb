# frozen_string_literal: true

module RubyLLM
  module Evaluations
    module Evaluators
      def self.action_group
        lambda do |_output, context|
          expected = context.expected_actions
          observed = context.response.actions
          raise ArgumentError, "action_group requires expected_actions (use [] to expect no actions)" if expected.nil?
          raise ArgumentError, "action trace missing; return Response with actions (use [] for observed no actions)" if observed.nil?
          size = [expected.size, observed.size].max
          matched = expected.each_with_index.count { |action, index| action == observed[index] }
          score = size.zero? ? 1.0 : matched.fdiv(size)
          Assessment.new(score: score,
                         reason: "Matched #{matched} of #{size} ordered actions; expected #{expected.size}, observed #{observed.size}. Group, name, and arguments must match; extra calls count against the score.")
        end
      end
    end
  end
end
