# frozen_string_literal: true

require "cgi"
require "digest"
require "erb"
require "json"
require "uri"
require "webrick"

module RubyLLM
  module Evaluations
    class Dashboard
      ASSET_DIRECTORY = File.expand_path("dashboard", __dir__).freeze
      PATH_PARSER = URI::RFC2396_Parser.new.freeze
      SECURITY_HEADERS = {
        "content-security-policy" => "default-src 'none'; style-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
        "x-content-type-options" => "nosniff",
        "referrer-policy" => "no-referrer",
        "cache-control" => "no-store"
      }.freeze
      TEMPLATES = %w[layout index run error].to_h do |name|
        [name, File.join(ASSET_DIRECTORY, "#{name}.erb")]
      end.freeze

      def initialize
        @templates = TEMPLATES.transform_values { |path| ERB.new(File.read(path), trim_mode: "-") }
        @stylesheet = File.read(File.join(ASSET_DIRECTORY, "dashboard.css"))
      end

      def call(env)
        # Keep mount state request-local when Rails shares this Rack app.
        dup.send(:respond_to_request, env)
      end

      def respond_to_request(env)
        method = env.fetch("REQUEST_METHOD", "GET")
        @script_name = validated_mount_path(env.fetch("SCRIPT_NAME", ""))
        unless %w[GET HEAD].include?(method)
          return response(405, error_page(405, "Method not allowed", "This dashboard is read-only."), "text/html; charset=utf-8", "allow" => "GET, HEAD")
        end

        status, headers, body = dispatch(env)
        [status, headers, method == "HEAD" ? [] : body]
      rescue ::ActiveRecord::ActiveRecordError
        status, headers, body = response(503, error_page(503, "Database configuration required", "Configure the host ActiveRecord connection and apply the evaluation migrations. Standalone users: run ruby_llm-agent-evaluations db:migrate."))
        [status, headers, method == "HEAD" ? [] : body]
      rescue ArgumentError, URI::InvalidURIError => error
        status, headers, body = response(400, error_page(400, "Invalid request", error.message))
        [status, headers, method == "HEAD" ? [] : body]
      end
      private :respond_to_request

      # Blocks until shutdown, like WEBrick::HTTPServer#start.
      def start(host: "127.0.0.1", port: 4567)
        raise Error, "dashboard is already running" if @server

        server = WEBrick::HTTPServer.new(
          BindAddress: host, Port: port,
          AccessLog: [], Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN)
        )
        @server = server
        server.mount_proc("/") do |request, reply|
          status, headers, body = call(
            "REQUEST_METHOD" => request.request_method,
            "PATH_INFO" => request.unparsed_uri.split("?", 2).first,
            "QUERY_STRING" => request.query_string.to_s,
            "SERVER_NAME" => request.host,
            "SERVER_PORT" => request.port.to_s,
            "rack.url_scheme" => "http"
          )
          reply.status = status
          headers.each { |key, value| reply[key] = value }
          reply.body = body.join
        end
        server.start
      ensure
        if server
          server.shutdown
          @server = nil if @server.equal?(server)
        end
      end

      def shutdown
        @server&.shutdown
      end

      private

      def dispatch(env)
        path = validated_path(env.fetch("PATH_INFO", "/"))
        query = parse_query(env.fetch("QUERY_STRING", ""))
        case path
        when "/assets/dashboard.css"
          validate_query(query, [])
          response(200, @stylesheet, "text/css; charset=utf-8", "cache-control" => "public, max-age=3600")
        when "/", "/api/runs"
          validate_query(query, %w[suite agent limit])
          limit = query.key?("limit") ? parse_limit(query.fetch("limit")) : 100
          records = Run.recent.with_results
          records = records.for_suite(filter(query["suite"])) if filter(query["suite"])
          records = records.for_agent(filter(query["agent"])) if filter(query["agent"])
          records = records.limit(limit).to_a
          if path == "/api/runs"
            response(200, JSON.generate(records.map(&:snapshot)), "application/json; charset=utf-8")
          else
            catalog = Run.recent.limit(1000).map { |run| { "suite" => run.suite, "agent" => run.agent } }
            reports = records.map { |run| report_for(run) }
            runs = reports.map(&:run)
            comparisons = reports.to_h { |report| [report.run.fetch("id"), report.comparison] }
            html = render("index", runs: runs, catalog: catalog, query: query, comparisons: comparisons, limit: limit)
            response(200, layout(html, "Evaluation history"))
          end
        when %r{\A/(api/runs|runs)/([A-Za-z0-9_-]+)\z}
          api = Regexp.last_match(1) == "api/runs"
          id = Regexp.last_match(2)
          validate_query(query, api ? ["download"] : [])
          raise ArgumentError, "download must be 1" if query.key?("download") && query["download"] != "1"
          run = Run.with_results.find_by(id: id)
          return response(404, error_page(404, "Run not found", "This run is not in your local history.")) unless run

          report = report_for(run)
          if api
            headers = query["download"] == "1" ? { "content-disposition" => "attachment; filename=\"evaluation-#{id}.json\"" } : {}
            response(200, report.to_json, "application/json; charset=utf-8", headers)
          else
            html = render("run", run: report.run, comparison: report.comparison)
            response(200, layout(html, run.suite))
          end
        else
          response(404, error_page(404, "Page not found", "Choose a run from evaluation history to continue."))
        end
      end

      def validated_path(path)
        raise ArgumentError, "invalid path" unless path.is_a?(String) && path.start_with?("/") && path.valid_encoding?
        raise ArgumentError, "invalid path encoding" if path.match?(/%(?![0-9a-fA-F]{2})/)

        decoded = PATH_PARSER.unescape(path).force_encoding(Encoding::UTF_8)
        unless decoded.valid_encoding? && !decoded.match?(/[\x00-\x1f\x7f\\]/) && !decoded.split("/").any? { |part| %w[. ..].include?(part) }
          raise ArgumentError, "invalid path"
        end
        raise ArgumentError, "encoded path separators are not allowed" if path.match?(/%(?:2f|5c)/i)

        decoded
      end

      def validated_mount_path(prefix)
        return "" if prefix == "" || prefix == "/"

        decoded = validated_path(prefix)
        raise ArgumentError, "invalid mount path" if decoded.include?("//") || decoded.match?(/[?#]/)

        decoded.delete_suffix("/").split("/").map { |part| URI.encode_www_form_component(part).gsub("+", "%20") }.join("/")
      end

      def parse_query(raw)
        raise ArgumentError, "query is too long" if raw.bytesize > 8192
        raise ArgumentError, "invalid query encoding" if raw.match?(/%(?![0-9a-fA-F]{2})/)

        URI.decode_www_form(raw, Encoding::UTF_8).each_with_object({}) do |(key, value), query|
          raise ArgumentError, "duplicate query parameter" if query.key?(key)
          raise ArgumentError, "invalid query value" if value.match?(/[\x00-\x1f\x7f]/) || value.include?("\uFFFD")

          query[key] = value
        end
      end

      def validate_query(query, allowed)
        raise ArgumentError, "unknown query parameter" unless (query.keys - allowed).empty?
      end

      def parse_limit(value)
        raise ArgumentError, "limit must be an integer between 1 and 1000" unless value.match?(/\A[1-9]\d{0,3}\z/) && value.to_i <= 1000

        value.to_i
      end

      def filter(value)
        value unless value.nil? || value.empty?
      end

      def report_for(run)
        Report.new(run, baseline: run.previous)
      end

      def response(status, body, content_type = "text/html; charset=utf-8", extra = {})
        headers = SECURITY_HEADERS.merge("content-type" => content_type, "content-length" => body.bytesize.to_s).merge(extra)
        [status, headers, [body]]
      end

      def render(name, locals)
        @templates.fetch(name).result_with_hash(locals.merge(ui: self))
      end

      def layout(content, title)
        render("layout", content: content, title: title)
      end

      def error_page(code, title, message)
        layout(render("error", code: code, title: title, message: message), title)
      end

      public

      # Template helpers always escape user/agent content at the HTML boundary.
      def h(value)
        CGI.escapeHTML(value.to_s)
      end

      def run_path(id)
        path("/runs/#{URI.encode_www_form_component(id)}")
      end

      def path(route)
        "#{@script_name}#{route}"
      end

      def report_path(id)
        path("/api/runs/#{URI.encode_www_form_component(id)}?download=1")
      end

      def pretty(value)
        value.is_a?(String) ? value : JSON.pretty_generate(value)
      end

      def percent(value)
        value.nil? ? "Not evaluated" : format("%.1f%%", value * 100)
      end

      def score(value)
        value.nil? ? "Not evaluated" : format("%.3f", value)
      end

      def delta(value, percentage: false)
        return "Not evaluated" if value.nil?
        format(percentage ? "%+.1f pp" : "%+.3f", value.to_f * (percentage ? 100 : 1))
      end

      def duration(milliseconds)
        milliseconds.to_f >= 1000 ? format("%.2f s", milliseconds.to_f / 1000) : format("%.0f ms", milliseconds.to_f)
      end

      def cost(value)
        value.nil? ? "—" : format("$%.4f", value)
      end

      def time(value)
        value.to_s.tr("T", " ").sub(/(?:\.\d+)?Z\z/, " UTC")
      end

      def trend(runs)
        ordered = runs.reverse
        groups = ordered.reject { |run| run["summary"]["score"].nil? }.group_by { |run| [run["suite"], run["agent"], run["suite_digest"]] }
        palette = %w[#087f8c #3657a3 #a85c22 #8b4f94 #377746 #a63756]
        x = ->(index) { ordered.size == 1 ? 480.0 : 62.0 + index * 850.0 / (ordered.size - 1) }
        indexes = ordered.each_with_index.to_h { |run, index| [run.fetch("id"), index] }
        series = groups.map do |(suite, agent, digest), values|
          color_index = Digest::SHA256.hexdigest(JSON.generate([suite, agent, digest])).to_i(16) % palette.length
          {
            label: "#{suite} · #{agent} · #{digest.to_s[0, 8]}", color: palette[color_index],
            points: values.map do |run|
              { x: x.call(indexes.fetch(run.fetch("id"))).round(2), y: (218 - run.fetch("summary").fetch("score").to_f * 176).round(2), run: run }
            end
          }
        end
        { series: series, first: ordered.first, last: ordered.last }
      end
    end
  end
end
