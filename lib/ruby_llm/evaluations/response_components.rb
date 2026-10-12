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

      # Thread#[] is fiber-local: nested/concurrent synchronous chats do not share evidence.
      def capture
        previous = Thread.current[:ruby_llm_evaluations_components]
        components = []
        Thread.current[:ruby_llm_evaluations_components] = components
        [yield, components]
      ensure
        Thread.current[:ruby_llm_evaluations_components] = previous
      end

      def record(tool, arguments, result)
        components = Thread.current[:ruby_llm_evaluations_components]
        return unless components
        definition = tool.class.response_component_definition
        raise ArgumentError, "declare response_component protocol: on #{tool.class}" unless definition
        payload = if defined?(::RubyLLM::Tool::Halt) && result.is_a?(::RubyLLM::Tool::Halt)
                    result.content
                  else
                    result
                  end
        component = definition.merge("payload" => payload, "tool_name" => tool.name, "arguments" => arguments || {})
        # Snapshot before later tool calls can mutate a reused result object.
        components << JSON.parse(JSON.generate(normalize([component]).first))
      end
    end

    # Opt in on an application's tool; preserve its original return value and callbacks.
    module ResponseComponentTool
      def self.included(base)
        base.extend(ClassMethods)
        base.prepend(Capture)
      end

      module ClassMethods
        def response_component(protocol:, version: nil)
          definition = { "protocol" => ResponseComponents.label(protocol, "component protocol").dup.freeze }
          definition["version"] = ResponseComponents.label(version, "component version").dup.freeze unless version.nil?
          @response_component_definition = definition.freeze
        end

        def response_component_definition
          return @response_component_definition if defined?(@response_component_definition)
          superclass.response_component_definition if superclass.respond_to?(:response_component_definition)
        end
      end

      module Capture
        def call(arguments)
          evidence_arguments = JSON.parse(JSON.generate(Data.json_value(arguments || {}))) if Thread.current[:ruby_llm_evaluations_components]
          result = super
          ResponseComponents.record(self, evidence_arguments, result)
          result
        end
      end
      private_constant :Capture, :ClassMethods
    end
  end
end
