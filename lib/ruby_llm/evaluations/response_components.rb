# frozen_string_literal: true

module RubyLLM
  module Evaluations
    module ResponseComponents
      module_function

      def normalize(value)
        raise ArgumentError, "components must be an array" unless value.is_a?(Array)
        value.map do |component|
          raise ArgumentError, "each response component must be a Hash" unless component.is_a?(Hash)
          component = Data.json_value(component)
          unknown = component.keys - %w[protocol version payload tool_name arguments]
          raise ArgumentError, "unknown response component fields: #{unknown.join(', ')}" unless unknown.empty?
          label(component["protocol"], "component protocol")
          label(component["version"], "component version") if component.key?("version")
          label(component["tool_name"], "component tool_name") if component.key?("tool_name")
          raise ArgumentError, "response component must include payload" unless component.key?("payload")
          if component.key?("arguments") && !component["arguments"].is_a?(Hash)
            raise ArgumentError, "component arguments must be a Hash"
          end
          component
        end
      end

      def label(value, name)
        raise ArgumentError, "#{name} must be a nonempty string" unless value.is_a?(String) && !value.strip.empty?
        value
      end

      def current = Thread.current[:ruby_llm_evaluations_components]

      # Fiber-local scope; always restore the enclosing evaluation after errors.
      def collect
        previous = current
        components = []
        Thread.current[:ruby_llm_evaluations_components] = components
        yield components
      ensure
        Thread.current[:ruby_llm_evaluations_components] = previous
      end

      def from_tool(tool, arguments, result)
        payload = if defined?(::RubyLLM::Tool::Halt) && result.is_a?(::RubyLLM::Tool::Halt)
                    result.content
                  else
                    result
                  end
        component = tool.response_component.merge(payload: payload, tool_name: tool.name, arguments: arguments)
        Data.snapshot(normalize([component]).first)
      end
    end

    # Prepend to a tool and declare its protocol with an ordinary response_component method.
    module ResponseComponentTool
      def call(arguments)
        components = ResponseComponents.current
        return super unless components

        evidence_arguments = Data.snapshot(arguments || {})
        result = super
        components << ResponseComponents.from_tool(self, evidence_arguments, result)
        result
      end
    end
  end
end
