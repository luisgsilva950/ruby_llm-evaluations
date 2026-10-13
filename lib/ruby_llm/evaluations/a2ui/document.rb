# frozen_string_literal: true

require "json"

module RubyLLM
  module Evaluations
    module A2UI
      # Replays protocol messages without rendering or resolving remote catalogs.
      class Document
        ACTIONS = %w[surfaceUpdate beginRendering dataModelUpdate deleteSurface].freeze
        VALUES = %w[valueString valueNumber valueBoolean valueMap].freeze
        private_constant :ACTIONS, :VALUES

        attr_reader :errors, :surfaces

        def initialize(catalogs)
          @catalogs = catalogs
          @errors = []
          @surfaces = {}
        end

        def read(response_components)
          @errors = []
          @surfaces = {}
          @records = []
          @locations = {}
          @component_locations = {}
          @message_index = 0
          unless response_components.is_a?(Array) && !response_components.empty?
            errors << "A2UI requires a nonempty response component envelope array"
            return self
          end
          response_components.each_with_index do |envelope, index|
            unless envelope.is_a?(Hash) && envelope.key?("payload")
              errors << "Envelope #{index + 1}: expected an object containing payload"
              next
            end
            messages(envelope["payload"], "Envelope #{index + 1}").each do |message|
              @message_index += 1
              replay(message)
            end
          end
          validate_records
          validate_surfaces
          unless surfaces.values.any? { |surface| surface["rendered"] }
            errors << "A2UI requires at least one live rendered surface"
          end
          self
        end

        private

        def messages(payload, location)
          if payload.is_a?(String)
            if payload.strip.empty?
              errors << "#{location}: payload is empty"
              return []
            end
            begin
              payload = JSON.parse(payload)
            rescue JSON::ParserError => error
              lines = payload.lines.reject { |line| line.strip.empty? }
              if lines.size < 2
                errors << "#{location}: malformed JSON: #{error.message}"
                return []
              end
              return lines.each_with_index.flat_map do |line, index|
                begin
                  messages(JSON.parse(line), "#{location}, JSONL line #{index + 1}")
                rescue JSON::ParserError => line_error
                  errors << "#{location}, JSONL line #{index + 1}: malformed JSON: #{line_error.message}"
                  []
                end
              end
            end
          end
          case payload
          when Hash then [payload]
          when Array
            errors << "#{location}: message array is empty" if payload.empty?
            payload
          else
            errors << "#{location}: payload must be a message object, message array, or JSON/JSONL string"
            []
          end
        end

        def replay(message)
          location = "Message #{@message_index}"
          unless message.is_a?(Hash)
            errors << "#{location}: message must be an object"
            return
          end
          actions = ACTIONS.select { |action| message.key?(action) }
          if actions.size != 1
            errors << "#{location}: message must contain exactly one action (#{ACTIONS.join(', ')})"
          end
          schema_errors = @catalogs.message_errors(message)
          action = actions.first
          body = message[action]
          if body.is_a?(Hash)
            location += ", surface #{body['surfaceId'].inspect}, /#{action}"
          end
          schema_errors.each { |error| errors << "#{location}: #{error}" }
          return unless actions.size == 1 && schema_errors.empty?

          id = body["surfaceId"]
          if action == "deleteSurface"
            surfaces.delete(id)
            return
          end
          surface = surfaces[id] ||= {
            "root" => nil, "catalog" => Catalogs::STANDARD_ID,
            "components" => {}, "styles" => {}, "rendered" => false
          }
          @locations[surface.object_id] = location
          case action
          when "surfaceUpdate"
            seen = {}
            body["components"].each_with_index do |component, index|
              component_id = component["id"]
              path = "#{location}/components/#{index}, component #{component_id.inspect}"
              errors << "#{path}: duplicate component ID within this update" if seen[component_id]
              seen[component_id] = true
              wrapper = component["component"]
              unless wrapper.size == 1
                errors << "#{path}/component: expected exactly one component type"
                next
              end
              type, props = wrapper.first
              record = { "type" => type, "props" => copy(props) }
              surface["components"][component_id] = record
              (@component_locations[surface.object_id] ||= {})[component_id] = path
              catalog = surface["rendered"] ? surface["catalog"] : surface
              @records << [catalog, :component, record, "#{path}/component/#{type}"]
            end
          when "beginRendering"
            catalog = copy(body.fetch("catalogId", Catalogs::STANDARD_ID))
            if surface["rendered"] && surface["catalog"] != catalog
              surface["components"].each do |component_id, component|
                path = "#{location}, component #{component_id.inspect}/component/#{component['type']}"
                @records << [catalog, :component, component, path]
              end
            end
            @records.each { |record| record[0] = catalog if record[0].equal?(surface) }
            surface["root"] = copy(body["root"])
            surface["catalog"] = catalog
            surface["styles"] = copy(body.fetch("styles", {}))
            surface["rendered"] = true
            @records << [catalog, :styles, surface["styles"], "#{location}/styles"]
            unless @catalogs.known?(surface["catalog"])
              errors << "#{location}/catalogId: unknown catalog #{surface['catalog'].inspect} (only registered offline catalogs are allowed)"
            end
          when "dataModelUpdate"
            validate_entries(body["contents"], "#{location}/contents")
          end
        end

        def validate_entries(entries, location)
          entries.each_with_index do |entry, index|
            path = "#{location}/#{index}"
            typed = VALUES.select { |key| entry.key?(key) }
            errors << "#{path}: data entry must contain exactly one typed value" unless typed.size == 1
            validate_entries(entry["valueMap"], "#{path}/valueMap") if entry["valueMap"].is_a?(Array)
          end
        end

        # Components may precede beginRendering, so catalog checks wait until replay
        # has selected the surface's catalog. Keep overwritten/deleted evidence too.
        def validate_records
          @records.each do |selection, kind, value, location|
            catalog = selection.is_a?(Hash) ? selection["catalog"] : selection
            next unless @catalogs.known?(catalog)
            failures = if kind == :component
              @catalogs.component_errors(catalog, value["type"], value["props"])
            else
              @catalogs.style_errors(catalog, value)
            end
            failures.each { |error| errors << "#{location}: #{error}" }
            if kind == :component && catalog == Catalogs::STANDARD_ID
              references(value, location)
            end
          end
        end

        def validate_surfaces
          surfaces.each do |id, surface|
            location = "#{@locations[surface.object_id]}, surface #{id.inspect}"
            if surface["rendered"] && !surface["components"].key?(surface["root"])
              errors << "#{location}/root: rendered root #{surface['root'].inspect} does not exist"
            end
            next unless surface["catalog"] == Catalogs::STANDARD_ID
            graph = {}
            surface["components"].each do |component_id, component|
              path = @component_locations.fetch(surface.object_id, {}).fetch(component_id, location)
              graph[component_id] = references(component, path, report: false)
              graph[component_id].each do |target, reference_path|
                unless surface["components"].key?(target)
                  errors << "#{reference_path}: dangling component reference #{target.inspect}"
                end
              end
            end
            validate_cycles(graph, location)
          end
        end

        def references(component, location, report: true)
          props = component["props"]
          return [] unless props.is_a?(Hash)
          refs = []
          case component["type"]
          when "Row", "Column", "List"
            children = props["children"]
            if children.is_a?(Hash)
              alternatives = %w[explicitList template].select { |key| children.key?(key) }
              if report && alternatives.size != 1
                errors << "#{location}/children: expected exactly one of explicitList or template"
              end
              if children["explicitList"].is_a?(Array)
                children["explicitList"].each_with_index { |id, index| refs << [id, "#{location}/children/explicitList/#{index}"] }
              end
              template = children["template"]
              refs << [template["componentId"], "#{location}/children/template/componentId"] if template.is_a?(Hash) && template.key?("componentId")
            end
          when "Card", "Button"
            refs << [props["child"], "#{location}/child"] if props.key?("child")
          when "Modal"
            %w[entryPointChild contentChild].each { |key| refs << [props[key], "#{location}/#{key}"] if props.key?(key) }
          when "Tabs"
            if props["tabItems"].is_a?(Array)
              props["tabItems"].each_with_index do |tab, index|
                refs << [tab["child"], "#{location}/tabItems/#{index}/child"] if tab.is_a?(Hash) && tab.key?("child")
              end
            end
          end
          refs
        end

        def validate_cycles(graph, location)
          state = {}
          graph.each_key do |start|
            next if state[start]
            stack = [[start, false]]
            until stack.empty?
              id, leaving = stack.pop
              if leaving
                state[id] = :done
                next
              end
              next if state[id] == :done
              state[id] = :visiting
              stack << [id, true]
              graph.fetch(id, []).reverse_each do |target, path|
                if state[target] == :visiting
                  errors << "#{path}: component reference cycle involving #{target.inspect}"
                elsif graph.key?(target) && !state[target]
                  stack << [target, false]
                end
              end
            end
          end
        end

        def copy(value)
          case value
          when Hash then value.to_h { |key, item| [key, copy(item)] }
          when Array then value.map { |item| copy(item) }
          when String then value.dup
          else value
          end
        end
      end
    end
  end
end
