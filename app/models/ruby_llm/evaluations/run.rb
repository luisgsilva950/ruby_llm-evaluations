# frozen_string_literal: true

require "securerandom"
require "time"

module RubyLLM
  module Evaluations
    class Run < ApplicationRecord
      self.table_name = "ruby_llm_evaluations_runs"
      self.primary_key = "id"
      attribute :metadata, default: -> { {} }

      has_many :case_results, -> { order(:position) }, inverse_of: :run,
               class_name: "RubyLLM::Evaluations::CaseResult", dependent: :restrict_with_exception
      accepts_nested_attributes_for :case_results

      scope :recent, -> { order(started_at: :desc, sequence: :desc) }
      scope :for_suite, ->(name) { name.nil? ? all : where(suite: name) }
      scope :for_agent, ->(name) { name.nil? ? all : where(agent: name) }
      scope :with_results, -> { includes(case_results: :metric_results) }

      before_validation :assign_identifier, on: :create
      validates :suite, :agent, :version, :suite_digest, :started_at, :finished_at, presence: true
      validates :status, inclusion: { in: ["completed"] }
      validate :validate_json

      def previous
        return unless persisted?

        self.class.where(suite: suite, agent: agent, suite_digest: suite_digest)
            .where("started_at < :time OR (started_at = :time AND sequence < :sequence)", time: started_at, sequence: sequence)
            .recent.with_results.first
      end

      def snapshot
        Data.json_value(
          id: id, suite: suite, agent: agent, version: version, suite_digest: suite_digest,
          started_at: started_at.utc.iso8601(6), finished_at: finished_at.utc.iso8601(6),
          status: status, metadata: metadata, summary: summary,
          cases: case_results.map(&:snapshot)
        )
      end

      private

      def assign_identifier
        self.id ||= SecureRandom.uuid
      end

      def validate_json
        normalize_json_attributes(:metadata, :summary)
        errors.add(:metadata, "must be a hash") unless metadata.is_a?(Hash)
        errors.add(:summary, "must be a hash") unless summary.is_a?(Hash)
      end
    end
  end
end
