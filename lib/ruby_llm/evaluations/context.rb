# frozen_string_literal: true

require "forwardable"

module RubyLLM
  module Evaluations
    class Context
      extend Forwardable
      attr_reader :question_data, :response, :judge
      def_delegators :@question_data, :id, :name, :question, :expected_answer, :expected_actions, :minimum_scores, :metadata

      def initialize(question_data, response, judge: nil)
        @question_data = question_data
        @response = response
        @judge = judge
      end
    end
  end
end
