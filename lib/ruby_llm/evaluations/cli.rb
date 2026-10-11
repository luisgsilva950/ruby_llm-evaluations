# frozen_string_literal: true

require "optparse"
require_relative "../evaluations"

module RubyLLM
  module Evaluations
    class CLI
      FORMATS = %w[text markdown html json].freeze

      def initialize(out: $stdout, err: $stderr)
        @out = out
        @err = err
      end

      def start(argv)
        args = argv.dup
        command = args.shift
        return help if command.nil? || %w[help --help -h].include?(command)
        if %w[--version -v].include?(command)
          @out.puts(VERSION)
          return 0
        end
        unless %w[run history report dashboard].include?(command)
          raise ArgumentError, "unknown command #{command.inspect}; use --help"
        end
        options = { database_url: ENV.fetch("DATABASE_URL", DEFAULT_DATABASE_URL), format: "text", tolerance: 0.0,
                    host: "127.0.0.1", port: 4567, limit: 100, metadata: {} }
        parser = parser_for(command, options)
        parser.parse!(args)
        return 0 if options[:help]
        store = Store.new(options[:database_url])
        begin
          case command
          when "run" then execute(args, options, store)
          when "history" then history(args, options, store)
          when "report" then report(args, options, store)
          when "dashboard" then dashboard(args, options, store)
          end
        ensure
          store.close
        end
      rescue OptionParser::ParseError, ArgumentError, Error, SystemCallError, JSON::ParserError, SyntaxError => exception
        @err.puts("#{exception.class}: #{exception.message}")
        2
      end

      private

      def parser_for(command, options)
        OptionParser.new do |parser|
          usage = { "run" => "run SPEC.rb", "history" => "history", "report" => "report [RUN_ID]",
                    "dashboard" => "dashboard" }.fetch(command)
          parser.banner = "Usage: ruby_llm-evaluations #{usage} [options]"
          parser.on("--database-url URL", "PostgreSQL URL (default: DATABASE_URL or local database)") { |value| options[:database_url] = value }
          if %w[run report].include?(command)
            parser.on("--format FORMAT", FORMATS, "text, markdown, html, or json") { |value| options[:format] = value }
            parser.on("--output PATH", "Write report to a file") { |value| options[:output] = value }
            parser.on("--baseline RUN_ID", "Compare against a specific compatible run") { |value| options[:baseline] = value }
            parser.on("--tolerance NUMBER", Float, "Ignore score drops up to this amount (0..1)") { |value| options[:tolerance] = value }
          end
          if command == "run"
            parser.on("--fail-on-regression", "Exit 1 on quality regression, even if every case passes") { options[:fail_on_regression] = true }
            parser.on("--metadata JSON", "Attach run metadata, e.g. revision or model") { |value| options[:metadata] = JSON.parse(value) }
          end
          if command == "history"
            parser.on("--suite NAME", "Filter by suite") { |value| options[:suite] = value }
            parser.on("--agent NAME", "Filter by agent") { |value| options[:agent] = value }
            parser.on("--limit NUMBER", Integer, "Maximum runs (default: 100)") { |value| options[:limit] = value }
          end
          if command == "dashboard"
            parser.on("--host HOST", "Bind address (default: 127.0.0.1)") { |value| options[:host] = value }
            parser.on("--port PORT", Integer, "HTTP port (default: 4567)") { |value| options[:port] = value }
          end
          parser.on("-h", "--help", "Show this command's help") do
            @out.puts(parser)
            options[:help] = true
          end
        end
      end

      def execute(args, options, store)
        raise ArgumentError, "run requires exactly one Ruby spec file" unless args.size == 1
        path = File.expand_path(args.first)
        suite = TOPLEVEL_BINDING.eval(File.read(path), path, 1)
        raise DefinitionError, "spec file must return a RubyLLM::Evaluations::Suite" unless suite.is_a?(Suite)
        explicit = explicit_baseline(options, store)
        if explicit && (explicit["suite"] != suite.name || explicit["agent"] != suite.agent_name || explicit["suite_digest"] != suite.digest)
          raise ArgumentError, "baseline has a different suite, agent, or evaluation definition"
        end
        validate_tolerance(options[:tolerance])
        run = Runner.new(store: store).run(suite, metadata: options[:metadata])
        result = build_report(run, options, store, explicit)
        emit(result, options)
        failed = run["summary"]["failed"].positive? || run["summary"]["errors"].positive?
        regressed = options[:fail_on_regression] && result.comparison && result.comparison["regressed"]
        failed || regressed ? 1 : 0
      end

      def history(args, options, store)
        raise ArgumentError, "history takes no positional arguments" unless args.empty?
        runs = store.list(suite: options[:suite], agent: options[:agent], limit: options[:limit])
        if runs.empty?
          @out.puts("No evaluation runs found.")
          return 0
        end
        @out.puts("RUN ID                                SUITE / AGENT                 PASS RATE   SCORE   STARTED")
        runs.each do |run|
          summary = run.fetch("summary")
          @out.puts(format("%-36s  %-28s %6.1f%%   %.3f   %s", run["id"], "#{run['suite']} / #{run['agent']}",
                           summary["pass_rate"] * 100, summary["score"], run["started_at"]))
        end
        0
      end

      def report(args, options, store)
        raise ArgumentError, "report takes at most one run ID" if args.size > 1
        run = args.empty? ? store.list(limit: 1).first : store.find(args.first)
        raise ArgumentError, "evaluation run not found" unless run
        validate_tolerance(options[:tolerance])
        emit(build_report(run, options, store, explicit_baseline(options, store)), options)
        0
      end

      def dashboard(args, options, store)
        raise ArgumentError, "dashboard takes no positional arguments" unless args.empty?
        unless options[:port].between?(1, 65_535)
          raise ArgumentError, "port must be between 1 and 65535"
        end
        app = Dashboard.new(store: store)
        previous_int = Signal.trap("INT") { app.shutdown }
        previous_term = Signal.trap("TERM") { app.shutdown }
        @out.puts("Evaluation dashboard: http://#{options[:host]}:#{options[:port]}")
        @out.flush
        begin
          app.start(host: options[:host], port: options[:port])
        ensure
          Signal.trap("INT", previous_int)
          Signal.trap("TERM", previous_term)
        end
        0
      end

      def explicit_baseline(options, store)
        return nil unless options[:baseline]
        store.find(options[:baseline]) || raise(ArgumentError, "baseline run not found: #{options[:baseline]}")
      end

      def build_report(run, options, store, explicit)
        baseline = explicit || store.latest(suite: run["suite"], agent: run["agent"],
                                           suite_digest: run["suite_digest"], before_id: run["id"])
        Report.new(run, baseline: baseline, tolerance: options[:tolerance])
      end

      def emit(report, options)
        content = report.public_send("to_#{options[:format]}")
        if options[:output]
          File.write(options[:output], content)
          @out.puts("Report written to #{options[:output]}")
        else
          @out.puts(content)
        end
      end

      def validate_tolerance(value)
        unless value.finite? && value.between?(0, 1)
          raise ArgumentError, "tolerance must be a finite number between 0 and 1"
        end
      end

      def help
        @out.puts(<<~HELP)
          ruby_llm-evaluations #{VERSION}
          Usage: ruby_llm-evaluations COMMAND [options]

          run SPEC.rb        Execute a code-defined evaluation and persist its results
          history            List previous runs, newest first
          report [RUN_ID]    Generate a text, Markdown, HTML, or JSON report (latest by default)
          dashboard          Start the read-only local evaluation dashboard

          Use COMMAND --help for options.
          Run exit codes: 0 passed, 1 failed/errored or requested regression gate, 2 configuration error.
          Ruby spec files execute trusted code with your process's permissions.
        HELP
        0
      end
    end
  end
end
