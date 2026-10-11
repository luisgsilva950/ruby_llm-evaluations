# frozen_string_literal: true

module RubyLLM
  module Evaluations
    class MetricResult < ApplicationRecord
      self.table_name = "ruby_llm_evaluations_metric_results"

      belongs_to :case_result, inverse_of: :metric_results, class_name: "RubyLLM::Evaluations::CaseResult"
      validates :name, presence: true
      validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
      validates :threshold, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
      validates :score, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
      validates :passed, inclusion: { in: [true, false] }
      validate { normalize_json_attributes(:error_details) }

      def snapshot
        Data.json_value(name: name, threshold: threshold, score: score,
                        passed: passed, reason: reason, error: error_details)
      end
    end
  end
end
