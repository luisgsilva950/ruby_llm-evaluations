# frozen_string_literal: true

module RubyLLM
  module Evaluations
    class Response
      attr_reader :output, :input_tokens, :output_tokens, :cost, :metadata, :actions, :components

      def initialize(output:, input_tokens: nil, output_tokens: nil, cost: nil, metadata: {}, actions: nil, components: nil)
        @output = output
        @input_tokens = tokens(input_tokens)
        @output_tokens = tokens(output_tokens)
        unless cost.nil? || (cost.is_a?(Numeric) && cost.finite? && cost >= 0)
          raise ArgumentError, "cost must be a finite nonnegative number"
        end
        raise ArgumentError, "response metadata must be a Hash" unless metadata.is_a?(Hash)
        if metadata.key?(:response_components) || metadata.key?("response_components")
          raise ArgumentError, "response_components is reserved; use components: instead"
        end
        @cost = cost&.to_f
        @metadata = Data.json_value(metadata)
        @actions = actions.nil? ? nil : Actions.normalize(actions)
        @components = components.nil? ? nil : ResponseComponents.normalize(components)
      end

      def self.normalize(value)
        return value if value.is_a?(self)
        return new(output: value) unless value.respond_to?(:content)

        new(output: value.content,
            input_tokens: value.respond_to?(:input_tokens) ? value.input_tokens : nil,
            output_tokens: value.respond_to?(:output_tokens) ? value.output_tokens : nil,
            metadata: message_metadata(value))
      end

      def self.message_metadata(value)
        %i[model_id role cached_tokens cache_creation_tokens thinking_tokens].each_with_object({}) do |field, metadata|
          next unless value.respond_to?(field)
          item = value.public_send(field)
          metadata[field] = item unless item.nil?
        end
      end

      private

      def tokens(value)
        unless value.nil? || (value.is_a?(Integer) && value >= 0)
          raise ArgumentError, "token counts must be nonnegative integers"
        end
        value
      end
    end

  end
end