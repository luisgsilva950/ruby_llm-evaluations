# frozen_string_literal: true

module RubyLLM
  module Evaluations
    # Collects marked tool results during one synchronous agent invocation.
    class ResponseComponentCapture
      attr_reader :components

      def self.current
        Thread.current[:ruby_llm_evaluations_component_capture]
      end

      def initialize
        @components = []
      end

      # Thread#[] is fiber-local; nested evaluations restore their enclosing capture.
      def around
        previous_capture = self.class.current
        Thread.current[:ruby_llm_evaluations_component_capture] = self
        yield
      ensure
        Thread.current[:ruby_llm_evaluations_component_capture] = previous_capture
      end

      def record_tool_call(tool, arguments)
        arguments_snapshot = Data.snapshot(arguments || {})
        result = yield

        component = tool.response_component.merge(
          tool_name: tool.name,
          arguments: arguments_snapshot,
          payload: tool_payload(result)
        )
        component_snapshot = Data.snapshot(component)
        @components << ResponseComponents.normalize_component(component_snapshot)

        result
      end

      private

      def tool_payload(result)
        if defined?(::RubyLLM::Tool::Halt) && result.is_a?(::RubyLLM::Tool::Halt)
          result.content
        else
          result
        end
      end
    end
  end
end
