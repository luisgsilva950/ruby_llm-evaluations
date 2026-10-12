# frozen_string_literal: true

require "digest"
require "uri"
require "thread"
require "webmock"
require_relative "data"

module RubyLLM
  module Evaluations
    class ApiReplay
      class Mismatch < Error; end

      UNSET = Object.new.freeze
      SCOPE_MUTEX = Mutex.new
      SENSITIVE = /authorization|cookie|(?:api[-_]?key)|token|password|secret|credential/i
      EVIDENCE_LIMIT = 4096
      private_constant :UNSET, :SCOPE_MUTEX, :SENSITIVE, :EVIDENCE_LIMIT

      class << self
        def immutable(value)
          case value
          when Hash
            value.to_h { |key, item| [immutable(key), immutable(item)] }.freeze
          when Array
            value.map { |item| immutable(item) }.freeze
          when String
            value.dup.freeze
          else
            value.freeze
          end
        end

        def json(value)
          normalized = Data.canonical(Data.json_value(value))
          JSON.generate(normalized)
          normalized
        rescue ArgumentError, JSON::GeneratorError => error
          raise DefinitionError, error.message
        end

        def headers(value)
          raise DefinitionError, "headers must be a Hash" unless value.is_a?(Hash)
          value.each_with_object({}) do |(key, item), result|
            unless (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s.match?(/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/)
              raise DefinitionError, "header names must be HTTP field names"
            end
            name = key.to_s.downcase
            raise DefinitionError, "duplicate header: #{name}" if result.key?(name)
            values = item.is_a?(Array) ? item : [item]
            unless !values.empty? && values.all? { |entry| entry.is_a?(String) && !entry.match?(/[\r\n]/) }
              raise DefinitionError, "header values must be strings without newlines"
            end
            result[name] = values.length == 1 ? values.first : values.sort
          end.sort.to_h
        end

        def endpoint(value, definition: false)
          uri = Addressable::URI.parse(value.to_s).normalize
          unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? && !uri.fragment
            raise DefinitionError, "request URL must be an absolute HTTP(S) URL without a fragment"
          end
          if definition && uri.userinfo
            raise DefinitionError, "request URL must not include credentials"
          end
          uri.user = uri.password = nil
          uri.query = nil
          uri.path = "/" if uri.path.nil? || uri.path.empty?
          uri.port = nil if uri.port == uri.default_port
          uri.to_s
        rescue Addressable::URI::InvalidURIError, TypeError
          raise DefinitionError, "request URL must be a valid HTTP(S) URL"
        end

        def query_pairs(value)
          return [] if value.nil? || value.empty?
          pairs = ::URI.decode_www_form(value, Encoding::UTF_8)
          raise ArgumentError unless pairs.flatten.all?(&:valid_encoding?)
          pairs
        rescue ArgumentError
          raise DefinitionError, "request URL query must be valid UTF-8 form encoding"
        end

        def query(value)
          raise DefinitionError, "query must be a Hash" unless value.is_a?(Hash)
          json(value).flat_map do |key, item|
            values = item.is_a?(Array) ? item : [item]
            values.map do |entry|
              if entry.is_a?(Hash) || entry.is_a?(Array)
                raise DefinitionError, "query values must be scalars or arrays of scalars"
              end
              [key, entry.nil? ? "" : entry.to_s]
            end
          end
        end

        def redact(value)
          case value
          when Hash
            value.to_h { |key, item| [key, key.match?(SENSITIVE) ? "[REDACTED]" : redact(item)] }
          when Array
            value.map { |item| redact(item) }
          else
            value
          end
        end

        def request_evidence(request)
          result = redact(request)
          result["query"] = request.fetch("query").map do |key, value|
            [key, key.match?(SENSITIVE) ? "[REDACTED]" : value]
          end
          if result.key?("json")
            bytes = JSON.generate(result["json"])
            if bytes.bytesize > EVIDENCE_LIMIT
              result["json"] = { "summary" => "JSON body omitted", "bytes" => bytes.bytesize,
                                 "sha256" => Digest::SHA256.hexdigest(JSON.generate(request["json"])) }
            end
          end
          result
        end
      end

      class Definition
        attr_reader :allow_hosts, :interactions, :fixture_hosts

        def initialize(base_dir:)
          @base_dir = File.expand_path(base_dir)
          @allow_hosts = []
          @interactions = []
          @declared = false
        end

        def api_interactions(allow_hosts: [], &block)
          mutable!
          raise DefinitionError, "api_interactions may only be declared once per question" if @declared
          raise DefinitionError, "api_interactions requires a block" unless block
          unless allow_hosts.is_a?(Array) && allow_hosts.all? { |host| valid_host?(host) }
            raise DefinitionError, "allow_hosts must contain exact host names, without URLs, ports, or wildcards"
          end
          @declared = true
          @allow_hosts = allow_hosts.map(&:downcase).uniq.sort
          @inside_interactions = true
          instance_eval(&block)
          self
        ensure
          @inside_interactions = false unless frozen?
        end

        def expect_request(method:, url:, query: {}, json: UNSET, headers: {})
          mutable!
          raise DefinitionError, "expect_request belongs inside api_interactions" unless @inside_interactions
          unless (method.is_a?(String) || method.is_a?(Symbol)) && method.to_s.match?(/\A[A-Za-z]+\z/)
            raise DefinitionError, "request method must be an HTTP method name"
          end
          raise DefinitionError, "request URL must be a string" unless url.is_a?(String)
          uri = Addressable::URI.parse(url)
          request = { "method" => method.to_s.upcase, "url" => ApiReplay.endpoint(url, definition: true),
                      "query" => (ApiReplay.query_pairs(uri.query) + ApiReplay.query(query)).sort,
                      "headers" => ApiReplay.headers(headers) }
          request["json"] = ApiReplay.json(json) unless json.equal?(UNSET)
          interaction = Interaction.new(request: request, base_dir: @base_dir)
          @interactions << interaction
          interaction
        rescue Addressable::URI::InvalidURIError
          raise DefinitionError, "request URL must be a valid HTTP(S) URL"
        end

        def validate!
          return self if frozen?
          raise DefinitionError, "question block requires api_interactions" unless @declared
          @interactions.each(&:validate!)
          @fixture_hosts = ApiReplay.immutable(@interactions.map { |interaction| Addressable::URI.parse(interaction.request.fetch("url")).host }.uniq)
          @allow_hosts = ApiReplay.immutable(@allow_hosts)
          @interactions.freeze
          @snapshot = ApiReplay.immutable(
            "allow_hosts" => @allow_hosts,
            "interactions" => @interactions.each_with_index.map { |interaction, index| interaction.to_h.merge("position" => index) }
          )
          freeze
        end

        def to_h
          validate!
          @snapshot
        end

        private

        def mutable!
          raise DefinitionError, "API replay definition is already validated" if frozen?
        end

        def valid_host?(host)
          return false unless host.is_a?(String) && !host.empty?
          host.match?(/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/) || host.match?(/\A\[[a-fA-F0-9:]+\]\z/)
        end
      end

      class Interaction
        attr_reader :request, :response

        def initialize(request:, base_dir:)
          @request = ApiReplay.immutable(request)
          @base_dir = base_dir
        end

        def respond_with(status: 200, headers: {}, json: UNSET, body_file: UNSET)
          raise DefinitionError, "response is already declared or validated" if frozen? || @response
          unless json.equal?(UNSET) != body_file.equal?(UNSET)
            raise DefinitionError, "respond_with requires exactly one of json or body_file"
          end
          unless status.is_a?(Integer) && status.between?(100, 599)
            raise DefinitionError, "response status must be an integer between 100 and 599"
          end
          response_headers = ApiReplay.headers(headers)
          bytes = if body_file.equal?(UNSET)
                    JSON.generate(ApiReplay.json(json))
                  else
                    fixture_body(body_file)
                  end
          @response = ApiReplay.immutable(status: status, headers: response_headers, body: bytes)
          self
        end

        def validate!
          raise DefinitionError, "each expect_request requires respond_with" unless @response
          freeze
        end

        def to_h
          validate!
          { "request" => ApiReplay.request_evidence(@request),
            "request_sha256" => Digest::SHA256.hexdigest(JSON.generate(@request)),
            "response" => { "status" => @response.fetch(:status), "headers" => ApiReplay.redact(@response.fetch(:headers)),
                            "headers_sha256" => Digest::SHA256.hexdigest(JSON.generate(@response.fetch(:headers))),
                            "body_sha256" => Digest::SHA256.hexdigest(@response.fetch(:body)),
                            "body_bytes" => @response.fetch(:body).bytesize } }
        end

        private

        def fixture_body(path)
          unless path.is_a?(String) && !path.empty? && !path.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
            raise DefinitionError, "body_file must be a nonempty filesystem path"
          end
          bytes = File.binread(File.expand_path(path, @base_dir)).force_encoding(Encoding::UTF_8)
          raise DefinitionError, "body_file must contain valid UTF-8 JSON" unless bytes.valid_encoding?
          JSON.parse(bytes)
          bytes
        rescue SystemCallError, IOError
          raise DefinitionError, "body_file could not be read: #{path}"
        rescue JSON::ParserError
          raise DefinitionError, "body_file must contain valid JSON: #{path}"
        end
      end

      def initialize(definition)
        unless definition.is_a?(Definition)
          raise ArgumentError, "API replay requires an ApiReplay::Definition"
        end
        @definition = definition.validate!
        @observations = []
        @next = 0
        @status = "pending"
        @request_mutex = Mutex.new
      end

      def call
        raise ArgumentError, "API replay requires a block" unless block_given?
        raise Error, "nested API replay is not supported" if SCOPE_MUTEX.owned?
        SCOPE_MUTEX.synchronize do
          @observations = []
          @next = 0
          @status = "failed"
          with_webmock do
            result = yield
            unless @next == @definition.interactions.length && @observations.none? { |item| item["status"] == "unmatched" }
              raise Mismatch, failure_message
            end
            @status = "passed"
            result
          end
        end
      end

      def evidence
        ApiReplay.immutable("status" => @status, "allow_hosts" => @definition.allow_hosts,
                            "expected" => @definition.to_h.fetch("interactions"),
                            "observations" => @observations,
                            "missing" => @definition.to_h.fetch("interactions").drop(@next))
      end

      private

      def live_request?(uri)
        @definition.allow_hosts.include?(uri.host.to_s.downcase) &&
          !@definition.fixture_hosts.include?(uri.host.to_s.downcase)
      end

      def intercept(signature)
        @request_mutex.synchronize do
          actual = actual_request(signature)
          interaction = @definition.interactions[@next]
          differences = interaction ? request_diff(interaction.request, actual) : ["unexpected request: no interactions remain"]
          matched = differences.empty?
          @observations << { "position" => @observations.length, "expected_position" => interaction ? @next : nil,
                             "status" => matched ? "matched" : "unmatched", "actual" => ApiReplay.request_evidence(actual),
                             "diff" => differences }
          raise Mismatch, "API replay mismatch: #{differences.join('; ')}" unless matched
          @next += 1
          interaction.response
        end
      end

      def actual_request(signature)
        body = signature.body.to_s.dup.force_encoding(Encoding::UTF_8)
        request = { "method" => signature.method.to_s.upcase, "url" => ApiReplay.endpoint(signature.uri),
                    "query" => ApiReplay.query_pairs(signature.uri.query).sort,
                    "headers" => ApiReplay.headers(signature.headers || {}) }
        unless body.empty?
          begin
            raise JSON::ParserError unless body.valid_encoding?
            request["json"] = Data.canonical(JSON.parse(body))
          rescue JSON::ParserError, EncodingError
            request["body"] = { "summary" => "non-JSON request body", "bytes" => body.bytesize,
                                "sha256" => Digest::SHA256.hexdigest(body) }
          end
        end
        request
      end

      def request_diff(expected, actual)
        safe_expected = ApiReplay.request_evidence(expected)
        safe_actual = ApiReplay.request_evidence(actual)
        differences = []
        %w[method url query].each do |field|
          next if expected[field] == actual[field]
          differences << "#{field}: expected #{JSON.generate(safe_expected[field])}, actual #{JSON.generate(safe_actual[field])}"
        end
        if expected.key?("json")
          unless actual.key?("json") && expected["json"] == actual["json"]
            differences << "json: expected #{JSON.generate(safe_expected['json'])}, actual #{actual.key?('json') ? JSON.generate(safe_actual['json']) : 'empty or non-JSON body'}"
          end
        elsif actual.key?("json") || actual.key?("body")
          value = safe_actual.key?("json") ? safe_actual["json"] : safe_actual["body"]
          differences << "body: expected an empty request body, actual #{JSON.generate(value)}"
        end
        expected.fetch("headers").each do |key, value|
          next if actual.fetch("headers")[key] == value
          differences << "header #{key}: expected #{JSON.generate(safe_expected['headers'][key])}, actual #{JSON.generate(safe_actual['headers'][key])}"
        end
        differences
      end

      def failure_message
        unmatched = @observations.count { |item| item["status"] == "unmatched" }
        missing = @definition.interactions.length - @next
        details = @observations.select { |item| item["status"] == "unmatched" }.flat_map { |item| item["diff"] }
        "API replay failed: #{unmatched} unmatched request(s), #{missing} missing interaction(s)#{details.empty? ? '' : ": #{details.join('; ')}"}"
      end

      # WebMock has no public scope/snapshot API. Suspend its registries rather than resetting
      # caller-owned stubs, and restore the original singleton state even when the agent raises.
      def with_webmock
        objects = [WebMock::StubRegistry.instance, WebMock::RequestRegistry.instance, WebMock::Config.instance]
        snapshots = objects.map { |object| [object, object.instance_variables.to_h { |key| [key, object.instance_variable_get(key)] }] }
        callbacks = WebMock::CallbackRegistry.callbacks
        uri_cache = WebMock::Util::URI::NORMALIZED_URIS.dup
        adapters = WebMock::HttpLibAdapterRegistry.instance.http_lib_adapters.map do |name, adapter|
          [name, adapter, adapter_enabled?(name, adapter)]
        end
        registry = WebMock::StubRegistry.instance
        registry.request_stubs = []
        registry.instance_variable_set(:@global_stubs, Hash.new { |hash, key| hash[key] = [] })
        WebMock::RequestRegistry.instance.reset!
        WebMock::CallbackRegistry.reset
        WebMock::Config.instance.query_values_notation = :flat_array
        WebMock::Util::URI::NORMALIZED_URIS.clear
        WebMock.disable_net_connect!(allow: ->(uri) { live_request?(uri) })
        stub = WebMock::RequestStub.new(:any, ->(uri) { !live_request?(uri) }).to_return { |request| intercept(request) }
        registry.global_stubs[:before_local_stubs] << stub
        WebMock.after_request(real_requests_only: true) do |request, _response|
          @request_mutex.synchronize do
            @observations << { "position" => @observations.length, "expected_position" => nil, "status" => "allowed",
                               "actual" => ApiReplay.request_evidence(actual_request(request)), "diff" => [] }
          end
        end
        adapters.each { |_name, adapter, enabled| adapter.enable! unless enabled }
        yield
      ensure
        if adapters
          adapters.each do |name, adapter, enabled|
            current = adapter_enabled?(name, adapter)
            adapter.public_send(enabled ? :enable! : :disable!) if current != enabled
          end
        end
        snapshots&.each do |object, snapshot|
          (object.instance_variables - snapshot.keys).each { |key| object.remove_instance_variable(key) }
          snapshot.each { |key, value| object.instance_variable_set(key, value) }
        end
        WebMock::CallbackRegistry.class_variable_set(:@@callbacks, callbacks) if callbacks
        WebMock::Util::URI::NORMALIZED_URIS.replace(uri_cache) if uri_cache
      end

      # WebMock 3.x adapters expose different activation mechanisms; do not infer all
      # adapter states from Net::HTTP (hosts can enable only selected transports).
      def adapter_enabled?(name, adapter)
        case name
        when :net_http then Net::HTTP != adapter::OriginalNetHTTP
        when :httpclient then ::HTTPClient != adapter::OriginalHttpClient
        when :patron then ::Patron::Session != adapter::OriginalPatronSession
        when :curb then ::Curl::Easy != adapter::OriginalCurlEasy
        when :em_http_request then ::EventMachine::HttpClient != adapter::OriginalHttpClient
        when :manticore then ::Manticore::Client != adapter::OriginalManticoreClient
        when :async_http_client then ::Async::HTTP::Client != adapter::OriginalAsyncHttpClient
        when :http_rb then !!adapter.enabled?
        when :typhoeus then ::Typhoeus.before.include?(adapter::BEFORE_CALLBACK)
        when :excon then !adapter.instance_variable_get(:@stub).nil?
        else
          raise Error, "unsupported WebMock adapter state: #{name}"
        end
      end
    end
  end
end
