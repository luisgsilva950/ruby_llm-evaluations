# frozen_string_literal: true

require "json"

module RubyLLM
  module Evaluations
    class Error < StandardError; end
    class DefinitionError < Error; end

    module Data
      module_function

      # Restrict persisted data to portable JSON values; never silently stringify objects.
      def json_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ArgumentError, "JSON object keys must be strings or symbols"
            end
            name = key.to_s
            raise ArgumentError, "duplicate JSON object key: #{name}" if result.key?(name)
            result[name] = json_value(item)
          end
        when Array
          value.map { |item| json_value(item) }
        when String, Integer, TrueClass, FalseClass, NilClass
          value
        when Symbol
          value.to_s
        when Float
          raise ArgumentError, "JSON numbers must be finite" unless value.finite?
          value
        else
          raise ArgumentError, "cannot persist #{value.class}; use JSON-compatible data"
        end
      end

      def snapshot(value)
        JSON.parse(JSON.generate(json_value(value)))
      end

      def canonical(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
        when Array
          value.map { |item| canonical(item) }
        else
          value
        end
      end

      def error(exception)
        { "class" => exception.class.name, "message" => exception.message }
      end
    end
  end
end
