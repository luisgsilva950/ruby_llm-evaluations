# frozen_string_literal: true

require "active_record"

module RubyLLM
  module Evaluations
    class ApplicationRecord < ::ActiveRecord::Base
      self.abstract_class = true

      def self.require_postgresql!
        unless connection_pool.db_config.adapter == "postgresql"
          raise Error, "evaluation history requires PostgreSQL"
        end
      end

      # Completed evidence is append-only through the model API.
      def readonly?
        persisted?
      end

      private

      def normalize_json_attributes(*names)
        names.each do |name|
          self[name] = Data.json_value(self[name])
        rescue ArgumentError => exception
          errors.add(name, exception.message)
        end
      end
    end
  end
end
