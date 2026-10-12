# frozen_string_literal: true

module RubyLLM
  module Evaluations
    # Prepend to a tool that defines response_component; preserve its call result.
    module ResponseComponentTool
      def call(arguments)
        capture = ResponseComponentCapture.current
        return super unless capture

        capture.record_tool_call(self, arguments) { super }
      end
    end
  end
end
