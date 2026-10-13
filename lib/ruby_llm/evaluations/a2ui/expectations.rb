# frozen_string_literal: true

module RubyLLM
  module Evaluations
    module A2UI
      # Business assertions are question data, so changing them changes the suite fingerprint.
      class Expectations
        def initialize(metadata, catalogs)
          value = metadata.key?(:a2ui) ? metadata[:a2ui] : metadata["a2ui"]
          @surfaces = {}
          return unless metadata.key?(:a2ui) || metadata.key?("a2ui")

          value = Data.json_value(value)
          fields!(value, %w[surfaces], "metadata.a2ui")
          @surfaces = value.fetch("surfaces", {})
          raise DefinitionError, "metadata.a2ui.surfaces must be a Hash" unless @surfaces.is_a?(Hash)
          @surfaces.each do |id, surface|
            label!(id, "surface ID")
            fields!(surface, %w[catalog root components], "surface #{id}")
            if surface.key?("catalog")
              label!(surface["catalog"], "surface #{id} catalog")
              unless catalogs.known?(catalog_id(surface["catalog"]))
                raise DefinitionError, "Unknown expected A2UI catalog: #{surface['catalog']}"
              end
            end
            label!(surface["root"], "surface #{id} root") if surface.key?("root")
            components = surface.fetch("components", {})
            raise DefinitionError, "surface #{id} components must be a Hash" unless components.is_a?(Hash)
            components.each do |component_id, component|
              label!(component_id, "component ID")
              fields!(component, %w[type props], "surface #{id} component #{component_id}")
              label!(component["type"], "component #{component_id} type") if component.key?("type")
              if component.key?("props") && !component["props"].is_a?(Hash)
                raise DefinitionError, "component #{component_id} props must be a Hash"
              end
            end
          end
        end

        def check(document)
          errors = []
          @surfaces.each do |id, expected|
            path = "surface #{id}"
            actual = document.surfaces[id]
            unless actual && actual["rendered"]
              errors << "#{path}: expected a rendered surface"
              next
            end
            compare(catalog_id(expected["catalog"]), actual["catalog"], "#{path} catalog", errors) if expected.key?("catalog")
            compare(expected["root"], actual["root"], "#{path} root", errors) if expected.key?("root")
            expected.fetch("components", {}).each do |component_id, component|
              component_path = "#{path} component #{component_id}"
              observed = actual.fetch("components")[component_id]
              unless observed
                errors << "#{component_path}: missing component"
                next
              end
              compare(component["type"], observed["type"], "#{component_path} type", errors) if component.key?("type")
              compare(component["props"], observed["props"], "#{component_path} props", errors) if component.key?("props")
            end
          end
          errors
        end

        private

        def compare(expected, actual, path, errors)
          if expected.is_a?(Hash) && actual.is_a?(Hash)
            expected.each do |key, value|
              if actual.key?(key)
                compare(value, actual[key], "#{path}.#{key}", errors)
              else
                errors << "#{path}.#{key}: missing property"
              end
            end
          elsif expected != actual
            errors << "#{path}: expected #{expected.inspect}, got #{actual.inspect}"
          end
        end

        def catalog_id(value)
          value == "standard" ? Catalogs::STANDARD_ID : value
        end

        def fields!(value, allowed, path)
          raise DefinitionError, "#{path} must be a Hash" unless value.is_a?(Hash)
          unknown = value.keys - allowed
          raise DefinitionError, "#{path}: unknown assertions #{unknown.join(', ')}" unless unknown.empty?
        end

        def label!(value, label)
          raise DefinitionError, "#{label} must be a nonempty String" unless value.is_a?(String) && !value.strip.empty?
        end
      end
    end
  end
end
