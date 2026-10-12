# frozen_string_literal: true

module RubyLLM
  module Evaluations
    class CaseResult < ApplicationRecord
      self.table_name = "ruby_llm_evaluations_case_results"
      attribute :metadata, default: -> { {} }
      attribute :minimum_scores, default: -> { {} }

      belongs_to :run, inverse_of: :case_results, class_name: "RubyLLM::Evaluations::Run"
      has_many :metric_results, -> { order(:position) }, inverse_of: :case_result,
               class_name: "RubyLLM::Evaluations::MetricResult", dependent: :restrict_with_exception
      accepts_nested_attributes_for :metric_results

      validates :case_id, :name, presence: true
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :status, inclusion: { in: %w[passed failed error not_evaluated] }
      validates :duration_ms, numericality: { greater_than_or_equal_to: 0 }
      validate :validate_json

      def snapshot
        Data.json_value(
          id: case_id, name: name, question: question, expected_answer: expected_answer,
          expected_actions: expected_actions, minimum_scores: minimum_scores,
          metadata: metadata, output: output, status: status, duration_ms: duration_ms,
          input_tokens: input_tokens, output_tokens: output_tokens, cost: cost, actions: actions,
          response_metadata: response_metadata, error: error_details,
          metrics: metric_results.map(&:snapshot)
        )
      end

      private

      def validate_json
        normalize_json_attributes(:question, :expected_answer, :expected_actions, :minimum_scores, :metadata,
                                  :output, :actions, :response_metadata, :error_details)
        errors.add(:metadata, "must be a hash") unless metadata.is_a?(Hash)
      end
    end
  end
end
