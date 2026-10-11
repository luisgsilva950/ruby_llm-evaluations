# frozen_string_literal: true

module RubyLLM
  module Evaluations
    module Actions
      module_function

      def normalize(value)
        raise ArgumentError, "actions must be an array" unless value.is_a?(Array)
        value.map do |action|
          raise ArgumentError, "each action must be a Hash" unless action.is_a?(Hash)
          action = Data.json_value(action)
          unknown = action.keys - %w[group name arguments]
          raise ArgumentError, "unknown action fields: #{unknown.join(', ')}" unless unknown.empty?
          name = action["name"]
          group = action["group"]
          arguments = action.fetch("arguments", {})
          unless name.is_a?(String) && !name.strip.empty?
            raise ArgumentError, "action name must be a nonempty string"
          end
          unless group.nil? || (group.is_a?(String) && !group.strip.empty?)
            raise ArgumentError, "action group must be a nonempty string or nil"
          end
          raise ArgumentError, "action arguments must be a Hash" unless arguments.is_a?(Hash)
          { "group" => group, "name" => name, "arguments" => arguments }
        end
      end
    end
  end
end
