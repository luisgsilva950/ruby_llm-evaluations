# frozen_string_literal: true

require "digest"

module RubyLLM
  module Evaluations
    Question = Struct.new(:id, :name, :question, :expected_answer, :expected_actions, :minimum_scores, :metadata,
                          :evaluators, :api_interactions, keyword_init: true) do
      def to_h
        super.reject { |key, _value| %i[evaluators api_interactions].include?(key) }
      end
    end
    Evaluator = Struct.new(:name, :callable, :threshold, keyword_init: true)

    class Suite
      SOURCE_DIRECTORY = Dir.pwd.freeze
      private_constant :SOURCE_DIRECTORY

      attr_reader :name, :agent, :agent_name, :version, :cases, :evaluators, :judge

      def initialize(name, agent:, judge: nil, agent_name: nil, version: "1")
        @name = nonempty(name, "suite name")
        @agent_name = nonempty(agent_name || name, "agent name")
        @version = nonempty(version, "version")
        raise DefinitionError, "agent must respond to call" unless agent.respond_to?(:call)
        unless judge.nil? || (judge.is_a?(Class) && defined?(::RubyLLM::Agent) && judge <= ::RubyLLM::Agent)
          raise DefinitionError, "judge must be a RubyLLM::Agent class"
        end
        @agent = agent
        @judge = judge
        @cases = []
        @evaluators = []
      end

      def question(value, expected_answer: nil, minimum_scores: nil, metadata: {}, name: nil, id: nil, expected_actions: nil, &block)
        name = nonempty(name || (value.is_a?(String) ? value : "Question #{cases.size + 1}"), "question name")
        id = nonempty(id || name, "question id")
        raise DefinitionError, "duplicate question id: #{id}" if cases.any? { |item| item.id == id }
        raise DefinitionError, "question metadata must be a Hash" unless metadata.is_a?(Hash)
        [value, expected_answer, metadata].each { |item| Data.json_value(item) }
        minimum_scores = normalize_minimum_scores(minimum_scores) unless minimum_scores.nil?
        unless expected_actions.nil?
          expected_actions = Actions.normalize(expected_actions)
          if expected_actions.any? { |action| action["group"].nil? }
            raise DefinitionError, "expected actions must specify an action group"
          end
        end
        if block
          source = block.source_location.first
          # Ruby main scripts can retain relative source locations after Dir.chdir.
          source = File.expand_path(source, File.file?(source) ? Dir.pwd : SOURCE_DIRECTORY)
          replay = ApiReplay::Definition.new(base_dir: File.dirname(source))
          replay.instance_eval(&block)
          replay.validate!
        end
        cases << Question.new(id: id, name: name, question: immutable_copy(value),
                              expected_answer: immutable_copy(expected_answer),
                              expected_actions: immutable_copy(expected_actions), api_interactions: replay,
                              minimum_scores: minimum_scores, metadata: immutable_copy(metadata)).freeze
      end

      def evaluate(name, using: nil, threshold: 1.0, &block)
        name = nonempty(name, "evaluator name")
        raise DefinitionError, "duplicate evaluator: #{name}" if evaluators.any? { |item| item.name == name }
        raise DefinitionError, "choose using: or a block, not both" if using && block
        callable = using || block
        raise DefinitionError, "evaluator must respond to call" unless callable.respond_to?(:call)
        validate_threshold(threshold)
        evaluators << Evaluator.new(name: name, callable: callable, threshold: threshold.to_f).freeze
      end

      def validate!
        raise DefinitionError, "suite must contain at least one question" if cases.empty?
        cases.map! do |item|
          minimum_scores = item.minimum_scores || if evaluators.empty?
                                                   { "semantic_accuracy" => 0.9, "answer_relevancy" => 0.9 }
                                                 else
                                                   evaluators.to_h { |definition| [definition.name, definition.threshold] }
                                                 end
          definitions = minimum_scores.filter_map do |metric_name, threshold|
            custom = evaluators.find { |definition| definition.name == metric_name }
            callable = custom ? custom.callable : standard_metric(metric_name)
            next if judge.nil? && callable.is_a?(JudgeMetric)
            callable.validate_expectations!(item.metadata) if callable.is_a?(A2UI::Evaluator)
            Evaluator.new(name: metric_name, callable: callable, threshold: threshold).freeze
          end.freeze
          Question.new(**item.to_h, minimum_scores: immutable_copy(minimum_scores),
                       api_interactions: item.api_interactions, evaluators: definitions).freeze
        end
        self
      end

      def digest
        validate!
        definition = { "name" => name, "version" => version,
                       "cases" => cases.map do |item|
                         # Persistent fingerprint labels are stable across public API renames.
                         data = item.to_h.transform_keys { |key| key == :minimum_scores ? :criteria : key }
                         data = data.merge(api_interactions: item.api_interactions.to_h) if item.api_interactions
                         skipped = item.minimum_scores.keys - item.evaluators.map(&:name)
                         data = data.merge(skipped_metrics: skipped) unless skipped.empty?
                         ui = item.evaluators.filter_map do |evaluator|
                           [evaluator.name, evaluator.callable.definition] if evaluator.callable.is_a?(A2UI::Evaluator)
                         end.to_h
                         data = data.merge(a2ui_evaluators: ui) unless ui.empty?
                         definition_value(data)
                       end }
        Digest::SHA256.hexdigest(JSON.generate(Data.canonical(definition)))
      end

      private

      def standard_metric(name)
        case name
        when "semantic_accuracy", "answer_relevancy"
          Evaluators.public_send(name)
        when "action_group"
          Evaluators.action_group
        when "a2ui"
          @a2ui_evaluator ||= Evaluators.a2ui
        else
          raise DefinitionError, "unknown metric: #{name}; register it with evaluate"
        end
      end

      def normalize_minimum_scores(minimum_scores)
        unless minimum_scores.is_a?(Hash) && !minimum_scores.empty?
          raise DefinitionError, "minimum_scores must be a nonempty Hash of metric names and minimum passing scores"
        end
        minimum_scores.each_with_object({}) do |(name, threshold), normalized|
          name = nonempty(name, "metric name")
          raise DefinitionError, "duplicate metric: #{name}" if normalized.key?(name)
          validate_threshold(threshold)
          normalized[name] = threshold.to_f
        end.freeze
      end

      def validate_threshold(threshold)
        unless threshold.is_a?(Numeric) && threshold.finite? && threshold.between?(0, 1)
          raise DefinitionError, "threshold must be a finite number between 0 and 1"
        end
      end

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