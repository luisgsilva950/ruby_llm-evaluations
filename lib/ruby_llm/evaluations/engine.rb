# frozen_string_literal: true

require "rails/engine"

module RubyLLM
  module Evaluations
    class Engine < ::Rails::Engine
      isolate_namespace RubyLLM::Evaluations
      engine_name "ruby_llm_evaluations"
      config.root = File.expand_path("../../..", __dir__)

      initializer "ruby_llm.evaluations.inflections", before: :setup_main_autoloader do
        Rails.autoloaders.main.inflector.inflect("ruby_llm" => "RubyLLM")
        Rails.autoloaders.once.inflector.inflect("ruby_llm" => "RubyLLM")
      end
    end
  end
end
