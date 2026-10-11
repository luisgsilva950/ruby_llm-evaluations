# frozen_string_literal: true

require "forwardable"

module RubyLLM
  module Evaluations
    class Context
      extend Forwardable
      attr_reader :question_data, :response
      def_delegators :@question_data, :id, :name, :question, :expected_answer, :expected_actions, :criteria, :metadata

      def initialize(question_data, response)
        @question_data = question_data
        @response = response
      end
    end
  end
end
