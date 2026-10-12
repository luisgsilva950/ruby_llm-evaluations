# frozen_string_literal: true

module RubyLLM
  module Evaluations
    class Runner
      def run(suite, metadata: {})
        suite.validate!
        raise Error, "Apply evaluation migrations before running a suite" unless Run.table_exists?
        raise ArgumentError, "run metadata must be a Hash" unless metadata.is_a?(Hash)
        run_metadata = Data.json_value(metadata)
        digest = suite.digest
        started_at = Time.now.utc
        started = clock
        # Finish all agent and evaluator calls before building/saving the database graph.
        results = suite.cases.map { |question| run_case(suite, question) }
        run = Run.new(suite: suite.name, agent: suite.agent_name, version: suite.version,
                      suite_digest: digest, started_at: started_at, finished_at: Time.now.utc,
                      status: "completed", metadata: run_metadata,
                      summary: summarize(results, milliseconds(started)))
        results.each_with_index do |result, position|
          attributes = result.except("id", "metrics", "error")
          record = run.case_results.build(attributes.merge("case_id" => result.fetch("id"),
                                                           "error_details" => result["error"],
                                                           "position" => position))
          result.fetch("metrics").each_with_index do |metric, metric_position|
            record.metric_results.build(metric.except("error").merge("error_details" => metric["error"],
                                                                     "position" => metric_position))
          end
        end
        # ActiveRecord save! atomically saves the autosaved associations in its short transaction.
        run.save!
        run.reload
      end

      private

      def run_case(suite, question)
        result = Data.json_value(question.to_h).merge(
          "output" => nil, "status" => "error", "input_tokens" => nil,
          "output_tokens" => nil, "cost" => nil, "actions" => nil, "error" => nil, "metrics" => []
        )
        started = clock
        replay = ApiReplay.new(question.api_interactions) if question.api_interactions
        begin
          invoke = -> { suite.agent.call(mutable_copy(question.question)) }
          raw_response, captured = ResponseComponents.capture { replay ? replay.call(&invoke) : invoke.call }
          response = Response.normalize(raw_response)
          unless captured.empty?
            response = Response.new(output: response.output, metadata: response.metadata, actions: response.actions,
              input_tokens: response.input_tokens, output_tokens: response.output_tokens, cost: response.cost,
              components: (response.components || []) + captured)
          end
          result.merge!("output" => Data.json_value(response.output),
                        "input_tokens" => response.input_tokens, "output_tokens" => response.output_tokens,
                        "cost" => response.cost, "response_metadata" => response.metadata,
                        "actions" => Data.json_value(response.actions))
          unless response.components.nil?
            result["response_metadata"] = response.metadata.merge("response_components" => response.components)
          end
        rescue StandardError => exception
          result["error"] = Data.error(exception)
          result["duration_ms"] = milliseconds(started)
          return result
        ensure
          if replay
            result["response_metadata"] = (result["response_metadata"] || {}).merge("api_replay" => replay.evidence)
          end
        end
        result["duration_ms"] = milliseconds(started)
        context = Context.new(question, response, judge: suite.judge)
        result["metrics"] = question.evaluators.map { |evaluator| assess(evaluator, response.output, context) }
        result["status"] = if result["metrics"].empty?
                             "not_evaluated"
                           elsif result["metrics"].any? { |item| item["error"] }
                             "error"
                           elsif result["metrics"].all? { |item| item["passed"] }
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
        evaluated = results.reject { |item| item["status"] == "not_evaluated" }
        # An agent error has no assessments; its case quality is zero, not missing data.
        scores = evaluated.map do |item|
          metrics = item["metrics"]
          metrics.empty? ? 0.0 : metrics.sum { |evaluation| evaluation["score"] || 0.0 } / metrics.size
        end
        {
          "cases" => results.size, "passed" => counts.fetch("passed", 0),
          "failed" => counts.fetch("failed", 0), "errors" => counts.fetch("error", 0),
          "not_evaluated" => counts.fetch("not_evaluated", 0), "evaluated_cases" => evaluated.size,
          "pass_rate" => evaluated.empty? ? nil : counts.fetch("passed", 0).fdiv(evaluated.size),
          "score" => scores.empty? ? nil : scores.sum / scores.size, "duration_ms" => duration,
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