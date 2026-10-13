# frozen_string_literal: true

require_relative "lib/ruby_llm/evaluations/version"

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-agent-evaluations"
  spec.version = RubyLLM::Evaluations::VERSION
  spec.authors = ["RubyLLM Evaluations contributors"]
  spec.summary = "Code-defined agent evaluations with persistent history, regression reports, and a dashboard"
  spec.description = "Evaluate any callable Ruby LLM agent with semantic, relevance, and action checks, persist runs through ActiveRecord, and inspect regressions in a local dashboard."
  spec.license = "MIT"
  spec.homepage = "https://github.com/luisgsilva950/ruby_llm-evaluations"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*", "app/models/**/*", "db/migrate/*.rb", "config/routes.rb", "exe/*", "README.md", "CHANGELOG.md", "LICENSE", "examples/**/*", "docs/images/*.png"]
  spec.bindir = "exe"
  spec.executables = ["ruby_llm-agent-evaluations"]
  spec.require_paths = ["lib"]
  spec.add_dependency "activerecord", ">= 7.1", "< 9"
  spec.add_dependency "json_schemer", "~> 2.0"
  spec.add_dependency "webrick", "~> 1.8"
  spec.add_dependency "webmock", "~> 3.26"
end
