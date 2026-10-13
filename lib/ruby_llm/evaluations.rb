# frozen_string_literal: true

require_relative "evaluations/version"
require_relative "evaluations/data"
require_relative "evaluations/actions"
require_relative "evaluations/response_components"
require_relative "evaluations/response_component_capture"
require_relative "evaluations/response_component_tool"
require_relative "evaluations/judge_metric"
require_relative "evaluations/evaluators"
require_relative "evaluations/a2ui/catalogs"
require_relative "evaluations/a2ui/document"
require_relative "evaluations/a2ui/expectations"
require_relative "evaluations/a2ui/evaluator"
require_relative "evaluations/api_replay"
require_relative "evaluations/suite"
require_relative "evaluations/response"
require_relative "evaluations/adapters"
require_relative "evaluations/context"
require_relative "evaluations/action_group"
require_relative "evaluations/runner"
require_relative "../../app/models/ruby_llm/evaluations/application_record"
require_relative "../../app/models/ruby_llm/evaluations/run"
require_relative "../../app/models/ruby_llm/evaluations/case_result"
require_relative "../../app/models/ruby_llm/evaluations/metric_result"
require_relative "evaluations/report"
require_relative "evaluations/dashboard"

module RubyLLM
  module Evaluations
    DEFAULT_DATABASE_URL = "sqlite3:ruby_llm_evaluations.sqlite3"
    MIGRATIONS_PATH = File.expand_path("../../db/migrate", __dir__).freeze
    autoload :Engine, File.expand_path("evaluations/engine", __dir__)

    def self.define(name, agent:, judge: nil, agent_name: nil, version: "1", &block)
      Suite.new(name, agent: agent, judge: judge, agent_name: agent_name, version: version).tap do |suite|
        suite.instance_eval(&block) if block
        suite.validate!
      end
    end

    def self.run(suite, metadata: {})
      Runner.new.run(suite, metadata: metadata)
    end

    # Standalone setup uses Rails migrations; a host application uses db:migrate.
    def self.migrate!
      ::ActiveRecord::MigrationContext.new([MIGRATIONS_PATH]).migrate
      [Run, CaseResult, MetricResult].each(&:reset_column_information)
    end
  end
end

require_relative "evaluations/engine" if defined?(::Rails::Engine)
