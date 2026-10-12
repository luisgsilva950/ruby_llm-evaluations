# frozen_string_literal: true

module RubyLLM
  module Evaluations
    module Adapters
      # The factory must return fresh chat state for each input. RubyLLM remains optional.
      def self.ruby_llm_chat(action_groups: {}, &factory)
        raise ArgumentError, "provide a chat factory block" unless factory
        raise ArgumentError, "action_groups must be a Hash" unless action_groups.is_a?(Hash)
        groups = Data.json_value(action_groups)
        groups.each do |name, group|
          unless !name.strip.empty? && group.is_a?(String) && !group.strip.empty?
            raise ArgumentError, "action_groups must map action names to nonempty group names"
          end
        end
        lambda do |input|
          chat = factory.call
          raw_answer, components = ResponseComponents.capture { chat.ask(input) }
          answer = Response.normalize(raw_answer)
          messages = chat.messages
          actions = messages.flat_map do |message|
            (message.tool_calls || {}).each_value.map do |call|
              { group: groups[call.name], name: call.name, arguments: call.arguments }
            end
          end
          assistant_messages = messages.select { |message| message.role == :assistant }
          Response.new(output: answer.output, metadata: answer.metadata, cost: answer.cost,
                       input_tokens: total_tokens(assistant_messages, :input_tokens),
                       output_tokens: total_tokens(assistant_messages, :output_tokens), actions: actions,
                       components: components + (answer.components || []))
        end
      end

      def self.total_tokens(messages, field)
        return nil if messages.empty?
        counts = messages.map { |message| message.public_send(field) }
        counts.any?(&:nil?) ? nil : counts.sum
      end
      private_class_method :total_tokens
    end
  end
end
