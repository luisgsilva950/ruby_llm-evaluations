# frozen_string_literal: true

require_relative "evaluations/version"
require_relative "evaluations/data"
require_relative "evaluations/actions"
require_relative "evaluations/evaluators"
require_relative "evaluations/suite"
require_relative "evaluations/response"
require_relative "evaluations/adapters"
require_relative "evaluations/context"
require_relative "evaluations/action_group"
require_relative "evaluations/runner"
require_relative "evaluations/store"
require_relative "evaluations/report"
require_relative "evaluations/dashboard"

module RubyLLM
  module Evaluations
    DEFAULT_DATABASE_URL = "postgresql://localhost/ruby_llm_evaluations"

    def self.define(name, agent:, agent_name: nil, version: "1", &block)
      Suite.new(name, agent: agent, agent_name: agent_name, version: version).tap do |suite|
        suite.instance_eval(&block) if block
        suite.validate!
      end
    end

    def self.run(suite, database_url: ENV.fetch("DATABASE_URL", DEFAULT_DATABASE_URL), metadata: {})
      store = Store.new(database_url)
      begin
        Runner.new(store: store).run(suite, metadata: metadata)
      ensure
        store.close
      end
    end
  end
end
