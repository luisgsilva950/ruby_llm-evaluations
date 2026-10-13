# frozen_string_literal: true

module RubyLLM
  module Evaluations
    module A2UI
      class Evaluator
        attr_reader :definition

        def initialize(version: "0.8", catalogs: {})
          raise ArgumentError, "Supported A2UI version is 0.8" unless version == "0.8"
          @catalogs = Catalogs.new(catalogs)
          @definition = { "version" => version.dup.freeze, "catalogs" => @catalogs.definitions }.freeze
          @check = Evaluators.response_components(protocol: "a2ui", version: version) do |components, context|
            document = Document.new(@catalogs).read(components)
            errors = document.errors
            errors += Expectations.new(context.metadata, @catalogs).check(document) if errors.empty?
            Assessment.new(score: errors.empty?, reason: errors.empty? ? "Valid A2UI 0.8 response" : errors.join("; "))
          end
        end

        def validate_expectations!(metadata)
          Expectations.new(metadata, @catalogs)
        end

        def call(output, context)
          @check.call(output, context)
        end
      end
    end

    module Evaluators
      def self.a2ui(version: "0.8", catalogs: {})
        A2UI::Evaluator.new(version: version, catalogs: catalogs)
      end
    end
  end
end
