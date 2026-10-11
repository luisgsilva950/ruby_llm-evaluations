# frozen_string_literal: true

require "forwardable"

module RubyLLM
  module Evaluations
    class Context
      extend Forwardable
      attr_reader :test_case, :response
      def_delegators :@test_case, :id, :name, :input, :expected, :expected_actions, :metadata

      def initialize(test_case, response)
        @test_case = test_case
        @response = response
      end
    end
  end
end
