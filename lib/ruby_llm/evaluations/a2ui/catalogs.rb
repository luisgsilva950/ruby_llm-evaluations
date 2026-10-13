# frozen_string_literal: true

require "json"
require "pathname"
require "json_schemer"
require_relative "../data"

module RubyLLM
  module Evaluations
    module A2UI
      class Catalogs
        STANDARD_ID = "https://a2ui.org/specification/v0_8/standard_catalog_definition.json".freeze
        ASSETS = File.expand_path("assets/v0_8", __dir__).freeze
        OFFLINE_RESOLVER = proc { |uri| raise ArgumentError, "external or unresolved schema reference: #{uri}" }.freeze

        attr_reader :definitions

        def initialize(custom_catalogs = {})
          raise ArgumentError, "catalogs must be a Hash" unless custom_catalogs.is_a?(Hash)
          standard = load_definition(File.join(ASSETS, "standard_catalog_definition.json"))
          standard["catalogId"] = STANDARD_ID
          @definitions = { STANDARD_ID => standard }
          custom_catalogs.each do |id, source|
            raise ArgumentError, "catalog ID must be a string or symbol" unless id.is_a?(String) || id.is_a?(Symbol)
            id = id.to_s
            raise ArgumentError, "cannot override standard catalog" if id == STANDARD_ID || id == "standard"
            raise ArgumentError, "duplicate catalog ID #{id.inspect}" if @definitions.key?(id)
            definition = load_definition(source)
            if definition.key?("catalogId") && definition["catalogId"] != id
              raise ArgumentError, "catalog #{id.inspect}: catalogId must match its configured ID"
            end
            definition["catalogId"] = id
            @definitions[id] = definition
          end
          @components = {}
          @styles = {}
          @definitions.each { |id, definition| configure(id, definition) }
          @message_schema = compile(JSON.parse(File.read(File.join(ASSETS, "server_to_client.json"))), "message schema")
          freeze_tree(@definitions)
        end

        def known?(id)
          @definitions.key?(id)
        end

        def message_errors(message)
          errors(@message_schema, message, "message")
        end

        def component_errors(catalog_id, type, props)
          id = catalog_id
          return ["unknown catalog #{catalog_id.inspect}"] unless known?(id)
          schema = @components.fetch(id)[type.to_s]
          return ["catalog #{id.inspect}: unknown component type #{type.inspect}"] unless schema
          errors(schema, props, "component #{type.inspect}")
        end

        def style_errors(catalog_id, styles)
          id = catalog_id
          return ["unknown catalog #{catalog_id.inspect}"] unless known?(id)
          return ["styles must be an object"] unless styles.is_a?(Hash)
          styles.flat_map do |name, value|
            schema = @styles.fetch(id)[name.to_s]
            schema ? errors(schema, value, "style #{name.inspect}") : ["catalog #{id.inspect}: unknown style #{name.inspect}"]
          end
        end

        private

        def load_definition(source)
          value = case source
                  when Hash then Data.snapshot(source)
                  when String, Pathname then JSON.parse(File.read(source.to_s))
                  else raise ArgumentError, "catalog definition must be a Hash or local JSON file path"
                  end
          raise ArgumentError, "catalog definition must be an object" unless value.is_a?(Hash)
          value
        rescue JSON::ParserError, SystemCallError => error
          raise ArgumentError, "invalid catalog definition: #{error.message}"
        end

        def configure(id, definition)
          compile(definition.slice("$schema", "$defs", "definitions"), "catalog #{id.inspect}")
          %w[components styles].each do |section|
            entries = definition[section]
            raise ArgumentError, "catalog #{id.inspect}: #{section} must be an object" unless entries.is_a?(Hash)
            compiled = entries.to_h do |name, schema|
              # Catalog-level definitions are shared; components can override them locally.
              schema = definition.slice("$schema", "$defs", "definitions").merge(schema) if schema.is_a?(Hash)
              [name, compile(schema, "catalog #{id.inspect} #{section}/#{name}")]
            end
            (section == "components" ? @components : @styles)[id] = compiled
          end
        end

        def compile(schema, label)
          unless schema.is_a?(Hash) || schema == true || schema == false
            raise ArgumentError, "#{label}: schema must be an object or boolean"
          end
          compiled = JSONSchemer.schema(schema, ref_resolver: OFFLINE_RESOLVER)
          failures = compiled.validate_schema.to_a
          unless failures.empty?
            raise ArgumentError, "#{label}: malformed schema: #{failures.map { |error| error['error'] }.join('; ')}"
          end
          # Resolve real schema references eagerly; annotation/default data is not schema.
          compiled.bundle
          compiled
        rescue ArgumentError
          raise
        rescue StandardError => error
          raise ArgumentError, "#{label}: invalid schema: #{error.message}"
        end

        def errors(schema, value, label)
          schema.validate(Data.json_value(value)).map do |error|
            pointer = error.fetch("data_pointer")
            "#{label} at #{pointer.empty? ? '/' : pointer}: #{error['error'] || error['type']}"
          end
        rescue ArgumentError => error
          ["#{label}: #{error.message}"]
        end

        def freeze_tree(value)
          case value
          when Hash
            value.each { |key, item| key.freeze; freeze_tree(item) }
          when Array
            value.each { |item| freeze_tree(item) }
          end
          value.freeze
        end
      end
    end
  end
end
