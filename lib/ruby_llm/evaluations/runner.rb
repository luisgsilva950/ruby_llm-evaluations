# frozen_string_literal: true

require "securerandom"
require "time"

module RubyLLM
  module Evaluations
    class Runner
      def initialize(store:)
        @store = store
      end

      def run(suite, metadata: {})
        suite.validate!
        raise ArgumentError, "run metadata must be a Hash" unless metadata.is_a?(Hash)
        run = {
          "id" => SecureRandom.uuid, "suite" => suite.name, "agent" => suite.agent_name,
          "suite_digest" => suite.digest, "started_at" => Time.now.utc.iso8601(6),
          "metadata" => Data.json_value(metadata)
        }
        started = clock
        results = suite.cases.map { |test_case| run_case(suite, test_case) }
        run.merge!("finished_at" => Time.now.utc.iso8601(6), "status" => "completed",
                   "summary" => summarize(results, milliseconds(started)), "cases" => results)
        @store.save(run)
        run
      end

      private

      def run_case(suite, test_case)
        result = Data.json_value(test_case.to_h).merge(
          "output" => nil, "status" => "error", "input_tokens" => nil,
          "output_tokens" => nil, "cost" => nil, "actions" => nil, "error" => nil, "evaluations" => []
        )
        started = clock
        begin
          response = Response.normalize(suite.agent.call(mutable_copy(test_case.input)))
          result.merge!("output" => Data.json_value(response.output),
                        "input_tokens" => response.input_tokens, "output_tokens" => response.output_tokens,
                        "cost" => response.cost, "response_metadata" => response.metadata,
                        "actions" => Data.json_value(response.actions))
        rescue StandardError => exception
          result["error"] = Data.error(exception)
          result["duration_ms"] = milliseconds(started)
          return result
        end
        result["duration_ms"] = milliseconds(started)
        context = Context.new(test_case, response)
        result["evaluations"] = suite.evaluators.map { |evaluator| assess(evaluator, response.output, context) }
        result["status"] = if result["evaluations"].any? { |item| item["error"] }
                             "error"
                           elsif result["evaluations"].all? { |item| item["passed"] }
                             "passed"
                           else
                             "failed"
                           end
        result
      end

      def assess(evaluator, output, context)
        result = { "name" => evaluator.name, "threshold" => evaluator.threshold,
                   "score" => nil, "passed" => false, "reason" => nil, "error" => nil }
        begin
          value = evaluator.callable.call(output, context)
          assessment = value.is_a?(Assessment) ? value : Assessment.new(score: value)
          score = case assessment.score
                  when true then 1.0
                  when false then 0.0
                  else assessment.score
                  end
          unless score.is_a?(Numeric) && score.finite? && score.between?(0, 1)
            raise ArgumentError, "evaluator must return a boolean or a finite score between 0 and 1"
          end
          unless assessment.reason.nil? || assessment.reason.is_a?(String)
            raise ArgumentError, "assessment reason must be a string"
          end
          result.merge!("score" => score.to_f, "passed" => score >= evaluator.threshold,
                        "reason" => assessment.reason)
        rescue StandardError => exception
          result["error"] = Data.error(exception)
        end
        result
      end

      def summarize(results, duration)
        counts = results.group_by { |item| item["status"] }.transform_values(&:size)
        # An agent error has no assessments; its case quality is zero, not missing data.
        scores = results.map do |item|
          evaluations = item["evaluations"]
          evaluations.empty? ? 0.0 : evaluations.sum { |evaluation| evaluation["score"] || 0.0 } / evaluations.size
        end
        {
          "cases" => results.size, "passed" => counts.fetch("passed", 0),
          "failed" => counts.fetch("failed", 0), "errors" => counts.fetch("error", 0),
          "pass_rate" => counts.fetch("passed", 0).fdiv(results.size),
          "score" => scores.sum / results.size, "duration_ms" => duration,
          "input_tokens" => results.sum { |item| item["input_tokens"] || 0 },
          "output_tokens" => results.sum { |item| item["output_tokens"] || 0 },
          "cost" => results.sum { |item| item["cost"] || 0.0 }
        }
      end

      def mutable_copy(value)
        case value
        when Hash then value.to_h { |key, item| [key, mutable_copy(item)] }
        when Array then value.map { |item| mutable_copy(item) }
        when String then value.dup
        else value
        end
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def milliseconds(started)
        (clock - started) * 1000.0
      end
    end
  end
end
