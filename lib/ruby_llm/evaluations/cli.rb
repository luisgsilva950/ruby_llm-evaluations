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
        unless %w[run history report dashboard db:migrate].include?(command)
          raise ArgumentError, "unknown command #{command.inspect}; use --help"
        end
        options = { database_url: ENV.fetch("DATABASE_URL", DEFAULT_DATABASE_URL), format: "text", tolerance: 0.0,
                    host: "127.0.0.1", port: 4567, limit: 100, metadata: {} }
        parser = parser_for(command, options)
        parser.parse!(args)
        return 0 if options[:help]
        begin
          ::ActiveRecord::Base.establish_connection(options[:database_url])
        rescue ArgumentError, URI::InvalidURIError
          raise Error, "Invalid database configuration. Set DATABASE_URL to a PostgreSQL connection URL."
        end
        if command == "db:migrate"
          raise ArgumentError, "db:migrate takes no positional arguments" unless args.empty?
          Evaluations.migrate!
          @out.puts("Evaluation database migrated.")
          return 0
        end
        unless [Run, CaseResult, MetricResult].all?(&:table_exists?)
          raise Error, "Evaluation tables are missing. Run ruby_llm-evaluations db:migrate, or install the engine migrations and run bin/rails db:migrate."
        end
        case command
        when "run" then execute(args, options)
        when "history" then history(args, options)
        when "report" then report(args, options)
        when "dashboard" then dashboard(args, options)
        end
      rescue ::ActiveRecord::ActiveRecordError
        @err.puts("Database configuration error. Check DATABASE_URL and PostgreSQL availability; run ruby_llm-evaluations db:migrate to create evaluation tables.")
        2
      rescue OptionParser::ParseError, ArgumentError, Error, SystemCallError, JSON::ParserError, SyntaxError => exception
        @err.puts("#{exception.class}: #{exception.message}")
        2
      end

      private

      def parser_for(command, options)
        OptionParser.new do |parser|
          usage = { "run" => "run SPEC.rb", "history" => "history", "report" => "report [RUN_ID]",
                    "dashboard" => "dashboard", "db:migrate" => "db:migrate" }.fetch(command)
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

      def execute(args, options)
        raise ArgumentError, "run requires exactly one Ruby spec file" unless args.size == 1
        path = File.expand_path(args.first)
        suite = TOPLEVEL_BINDING.eval(File.read(path), path, 1)
        raise DefinitionError, "spec file must return a RubyLLM::Evaluations::Suite" unless suite.is_a?(Suite)
        explicit = explicit_baseline(options)
        if explicit && (explicit["suite"] != suite.name || explicit["agent"] != suite.agent_name || explicit["suite_digest"] != suite.digest)
          raise ArgumentError, "baseline has a different suite, agent, or evaluation definition"
        end
        if explicit && explicit.started_at >= Time.now.utc
          raise ArgumentError, "baseline must be earlier than the current run"
        end
        validate_tolerance(options[:tolerance])
        run = Evaluations.run(suite, metadata: options[:metadata])
        result = build_report(run, options, explicit)
        emit(result, options)
        failed = run["summary"]["failed"].positive? || run["summary"]["errors"].positive?
        regressed = options[:fail_on_regression] && result.comparison && result.comparison["regressed"]
        failed || regressed ? 1 : 0
      end

      def history(args, options)
        raise ArgumentError, "history takes no positional arguments" unless args.empty?
        raise ArgumentError, "limit must be between 1 and 1000" unless options[:limit].between?(1, 1000)
        runs = Run.recent
        runs = runs.for_suite(options[:suite]) if options[:suite]
        runs = runs.for_agent(options[:agent]) if options[:agent]
        runs = runs.limit(options[:limit])
        if runs.empty?
          @out.puts("No evaluation runs found.")
          return 0
        end
        @out.puts("RUN ID                                SUITE / AGENT                 PASS RATE   SCORE   STARTED")
        runs.each do |run|
          summary = run.summary
          pass_rate = summary["pass_rate"].nil? ? "—" : format("%.1f%%", summary["pass_rate"] * 100)
          score = summary["score"].nil? ? "—" : format("%.3f", summary["score"])
          @out.puts(format("%-36s  %-28s %8s   %5s   %s", run["id"], "#{run['suite']} / #{run['agent']}",
                           pass_rate, score, run["started_at"]))
        end
        0
      end

      def report(args, options)
        raise ArgumentError, "report takes at most one run ID" if args.size > 1
        run = args.empty? ? Run.recent.with_results.first : Run.with_results.find_by(id: args.first)
        raise ArgumentError, "evaluation run not found" unless run
        validate_tolerance(options[:tolerance])
        emit(build_report(run, options, explicit_baseline(options)), options)
        0
      end

      def dashboard(args, options)
        raise ArgumentError, "dashboard takes no positional arguments" unless args.empty?
        unless options[:port].between?(1, 65_535)
          raise ArgumentError, "port must be between 1 and 65535"
        end
        app = Dashboard.new
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

      def explicit_baseline(options)
        return nil unless options[:baseline]
        Run.with_results.find_by(id: options[:baseline]) || raise(ArgumentError, "baseline run not found: #{options[:baseline]}")
      end

      def build_report(run, options, explicit)
        baseline = explicit || run.previous
        Report.new(run, baseline: baseline, tolerance: options[:tolerance])
      end

      def emit(report, options)
        if options[:output]
          report.export(options[:output], format: options[:format])
          @out.puts("Report written to #{options[:output]}")
        else
          @out.puts(report.public_send("to_#{options[:format]}"))
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
          db:migrate         Apply evaluation database migrations

          Use COMMAND --help for options.
          Run exit codes: 0 passed, 1 failed/errored or requested regression gate, 2 configuration error.
          Ruby spec files execute trusted code with your process's permissions.
        HELP
        0
      end
    end
  end
end
