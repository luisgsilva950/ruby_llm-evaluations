# frozen_string_literal: true

module RubyLLM
  module Evaluations
    module ResponseComponents
      module_function

      def normalize(components)
        raise ArgumentError, "components must be an array" unless components.is_a?(Array)

        components.map { |component| normalize_component(component) }
      end

      def normalize_component(component)
        raise ArgumentError, "each response component must be a Hash" unless component.is_a?(Hash)

        component = Data.json_value(component)
        unknown_fields = component.keys - %w[protocol version payload tool_name arguments]
        unless unknown_fields.empty?
          raise ArgumentError, "unknown response component fields: #{unknown_fields.join(', ')}"
        end

        validate_label!(component["protocol"], "component protocol")
        validate_label!(component["version"], "component version") if component.key?("version")
        validate_label!(component["tool_name"], "component tool_name") if component.key?("tool_name")
        raise ArgumentError, "response component must include payload" unless component.key?("payload")
        if component.key?("arguments") && !component["arguments"].is_a?(Hash)
          raise ArgumentError, "component arguments must be a Hash"
        end

        component
      end

      def validate_label!(value, name)
        unless value.is_a?(String) && !value.strip.empty?
          raise ArgumentError, "#{name} must be a nonempty string"
        end
        value
      end
    end
  end
end
