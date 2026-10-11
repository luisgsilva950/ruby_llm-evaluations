# frozen_string_literal: true

require "digest"

module RubyLLM
  module Evaluations
    TestCase = Struct.new(:id, :name, :input, :expected, :expected_actions, :metadata, keyword_init: true)
    Evaluator = Struct.new(:name, :callable, :threshold, keyword_init: true)

    class Suite
      attr_reader :name, :agent, :agent_name, :version, :cases, :evaluators

      def initialize(name, agent:, agent_name: nil, version: "1")
        @name = nonempty(name, "suite name")
        @agent_name = nonempty(agent_name || name, "agent name")
        @version = nonempty(version, "version")
        raise DefinitionError, "agent must respond to call" unless agent.respond_to?(:call)
        @agent = agent
        @cases = []
        @evaluators = []
      end

      def test(name, input:, expected: nil, expected_actions: nil, id: nil, metadata: {})
        name = nonempty(name, "case name")
        id = nonempty(id || name, "case id")
        raise DefinitionError, "duplicate case id: #{id}" if cases.any? { |item| item.id == id }
        raise DefinitionError, "case metadata must be a Hash" unless metadata.is_a?(Hash)
        [input, expected, metadata].each { |value| Data.json_value(value) }
        unless expected_actions.nil?
          expected_actions = Actions.normalize(expected_actions)
          if expected_actions.any? { |action| action["group"].nil? }
            raise DefinitionError, "expected actions must specify an action group"
          end
        end
        cases << TestCase.new(id: id, name: name, input: immutable_copy(input),
                              expected: immutable_copy(expected), expected_actions: immutable_copy(expected_actions),
                              metadata: immutable_copy(metadata)).freeze
      end

      def evaluate(name, using: nil, threshold: 1.0, &block)
        name = nonempty(name, "evaluator name")
        raise DefinitionError, "duplicate evaluator: #{name}" if evaluators.any? { |item| item.name == name }
        raise DefinitionError, "choose using: or a block, not both" if using && block
        callable = using || block
        raise DefinitionError, "evaluator must respond to call" unless callable.respond_to?(:call)
        unless threshold.is_a?(Numeric) && threshold.finite? && threshold.between?(0, 1)
          raise DefinitionError, "threshold must be a finite number between 0 and 1"
        end
        evaluators << Evaluator.new(name: name, callable: callable, threshold: threshold.to_f).freeze
      end

      def validate!
        raise DefinitionError, "suite must contain at least one case" if cases.empty?
        raise DefinitionError, "suite must contain at least one evaluator" if evaluators.empty?
        self
      end

      def digest
        definition = {
          "name" => name, "version" => version,
          "cases" => cases.map { |item| definition_value(item.to_h) },
          "evaluators" => evaluators.map { |item| { "name" => item.name, "threshold" => item.threshold } }
        }
        Digest::SHA256.hexdigest(JSON.generate(Data.canonical(definition)))
      end

      private

      # JSON snapshots normalize symbols, but Ruby agents distinguish key/value types.
      def definition_value(value)
        case value
        when Hash
          entries = value.map { |key, item| [key.class.name, key.to_s, definition_value(item)] }
          { "hash" => entries.sort_by { |type, name, _item| [type, name] } }
        when Array
          value.map { |item| definition_value(item) }
        when Symbol
          { "symbol" => value.to_s }
        else
          value
        end
      end

      def nonempty(value, label)
        raise DefinitionError, "#{label} must not be empty" if value.to_s.strip.empty?
        value.to_s.dup.freeze
      end

      def immutable_copy(value)
        case value
        when Hash
          value.to_h { |key, item| [immutable_copy(key), immutable_copy(item)] }.freeze
        when Array
          value.map { |item| immutable_copy(item) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end
    end
  end
end
