# frozen_string_literal: true

require "cgi"
require "json"

module RubyLLM
  module Evaluations
    class Report
      def initialize(run, baseline: nil, tolerance: 0.0)
        unless tolerance.is_a?(Numeric) && tolerance.finite? && tolerance >= 0
          raise ArgumentError, "tolerance must be a finite nonnegative number"
        end
        raise ArgumentError, "run must be a RubyLLM::Evaluations::Run" unless run.is_a?(Run)
        raise ArgumentError, "baseline must be a RubyLLM::Evaluations::Run" if baseline && !baseline.is_a?(Run)
        @run = run.snapshot
        @baseline = baseline&.snapshot
        @tolerance = tolerance.to_f
        if @baseline && %w[suite agent suite_digest].any? { |key| @run.fetch(key) != @baseline.fetch(key) }
          raise ArgumentError, "baseline must have the same suite, agent, and suite digest"
        end
        if baseline && ([baseline.started_at, baseline.sequence] <=> [run.started_at, run.sequence]) >= 0
          raise ArgumentError, "baseline must be earlier than the current run"
        end
        @comparison = compare if @baseline
      end

      def comparison
        @comparison
      end

      attr_reader :run
      def export(path, format: nil)
        path = File.path(path)
        format ||= { ".html" => "html", ".htm" => "html", ".json" => "json", ".md" => "markdown",
                     ".markdown" => "markdown", ".txt" => "text", ".text" => "text" }[File.extname(path).downcase]
        unless %w[text markdown html json].include?(format.to_s)
          raise ArgumentError, "report format must be text, markdown, html, or json"
        end
        File.write(path, public_send("to_#{format}"))
        path
      end

      def to_json(*args)
        @run.merge("comparison" => comparison).to_json(*args)
      end

      def to_text
        sections.map do |title, values|
          ([title, "=" * title.length] + values.map do |label, value|
            "#{label}: #{display_value(value).gsub("\n", "\n  ")}"
          end).join("\n")
        end.join("\n\n") + "\n"
      end

      def to_markdown
        sections.map.with_index do |(title, values), index|
          heading = "#{index.zero? ? '#' : '##'} #{markdown_escape(title)}"
          body = values.map do |label, value|
            text = display_value(value)
            if value.is_a?(Hash) || value.is_a?(Array) || text.include?("\n")
              fence = "`" * [3, (text.scan(/`+/).map(&:length).max || 0) + 1].max
              "**#{markdown_escape(label)}**\n\n#{fence}\n#{text}\n#{fence}"
            else
              "**#{markdown_escape(label)}:** #{markdown_escape(text)}"
            end
          end.join("\n\n")
          "#{heading}\n\n#{body}"
        end.join("\n\n") + "\n"
      end

      def to_html
        body = sections.map.with_index do |(title, values), index|
          level = index.zero? ? 1 : 2
          entries = values.map do |label, value|
            "<dt>#{html_escape(label)}</dt><dd><pre>#{html_escape(display_value(value))}</pre></dd>"
          end.join
          "<section><h#{level}>#{html_escape(title)}</h#{level}><dl>#{entries}</dl></section>"
        end.join("\n")
        <<~HTML
          <!doctype html>
          <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
          <title>#{html_escape(@run.fetch("suite"))} — Evaluation report</title>
          <style>
            :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
            body { max-width: 960px; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
            section { border-bottom: 1px solid #888; padding-bottom: 1rem; }
            dt { font-weight: 650; margin-top: 1rem; }
            dd { margin: .25rem 0 0; }
            pre { white-space: pre-wrap; overflow-wrap: anywhere; margin: 0; font: inherit; }
          </style></head><body>#{body}</body></html>
        HTML
      end

      private

      def compare
        regressions = []
        improvements = []
        previous = @baseline.fetch("cases").to_h { |item| [item.fetch("id"), item] }
        current = @run.fetch("cases").to_h { |item| [item.fetch("id"), item] }
        (previous.keys | current.keys).each do |id|
          before = previous[id]
          after = current[id]
          if after.nil?
            regressions << change(before, nil, nil, case_score(before), nil, "Case result is missing")
          elsif before.nil?
            improvements << change(nil, after, nil, nil, case_score(after), "Case result was added")
          else
            compare_case(before, after, regressions, improvements)
          end
        end
        baseline_summary = @baseline.fetch("summary")
        current_summary = @run.fetch("summary")
        {
          "baseline_id" => @baseline.fetch("id"), "current_id" => @run.fetch("id"),
          "compatible" => true, "regressed" => !regressions.empty?,
          "pass_rate_delta" => score_delta(baseline_summary["pass_rate"], current_summary["pass_rate"]),
          "score_delta" => score_delta(baseline_summary["score"], current_summary["score"]),
          "regressions" => regressions, "improvements" => improvements
        }
      end

      def compare_case(before, after, regressions, improvements)
        if agent_error?(after) && !agent_error?(before)
          regressions << change(before, after, nil, case_score(before), 0.0, "Agent execution began raising an error")
          return
        elsif agent_error?(before) && !agent_error?(after)
          improvements << change(before, after, nil, 0.0, case_score(after), "Agent execution recovered from an error")
          return
        elsif agent_error?(before) && agent_error?(after)
          return
        end

        old_evaluations = before.fetch("metrics").to_h { |item| [item.fetch("name"), item] }
        new_evaluations = after.fetch("metrics").to_h { |item| [item.fetch("name"), item] }
        regression_count = regressions.length
        improvement_count = improvements.length
        (old_evaluations.keys | new_evaluations.keys).each do |name|
          old_result = old_evaluations[name]
          new_result = new_evaluations[name]
          if new_result.nil?
            regressions << change(before, after, name, evaluation_score(old_result), nil, "Evaluator result is missing")
            next
          elsif old_result.nil?
            target = new_result["passed"] ? improvements : regressions
            target << change(before, after, name, nil, evaluation_score(new_result), "Evaluator result was added #{new_result['passed'] ? 'and passed' : 'without passing'}")
            next
          end

          old_score = evaluation_score(old_result)
          new_score = evaluation_score(new_result)
          reason = nil
          target = nil
          if new_result["error"] && !old_result["error"]
            reason, target = "Evaluator began raising an error", regressions
          elsif old_result["error"] && !new_result["error"]
            reason, target = "Evaluator recovered from an error", improvements
          elsif old_result["passed"] && !new_result["passed"]
            reason, target = "Evaluator changed from passing to failing", regressions
          elsif !old_result["passed"] && new_result["passed"]
            reason, target = "Evaluator changed from failing to passing", improvements
          elsif old_score && new_score && old_score - new_score > @tolerance
            reason, target = "Evaluator score decreased beyond tolerance", regressions
          elsif old_score && new_score && new_score - old_score > @tolerance
            reason, target = "Evaluator score increased beyond tolerance", improvements
          end
          target << change(before, after, name, old_score, new_score, reason) if target
        end
        # A case outcome without a changed evaluator is still evidence; do not duplicate evaluator failures.
        if before["status"] == "passed" && after["status"] != "passed" && regressions.length == regression_count
          regressions << change(before, after, nil, case_score(before), case_score(after), "Case changed from passing to #{after['status']}")
        elsif before["status"] != "passed" && after["status"] == "passed" && improvements.length == improvement_count
          improvements << change(before, after, nil, case_score(before), case_score(after), "Case changed from #{before['status']} to passing")
        end
      end

      def agent_error?(item)
        !item["error"].nil?
      end

      def evaluation_score(item)
        item["error"] ? 0.0 : item["score"]
      end

      def case_score(item)
        return 0.0 if agent_error?(item)
        return nil if item["status"] == "not_evaluated"

        scores = item.fetch("metrics").map { |evaluation| evaluation_score(evaluation) || 0.0 }
        scores.empty? ? (item["status"] == "passed" ? 1.0 : 0.0) : scores.sum.to_f / scores.length
      end
      def score_delta(before, after)
        after - before unless before.nil? || after.nil?
      end

      def change(before, after, evaluator, old_score, new_score, reason)
        item = after || before
        {
          "case_id" => item.fetch("id"), "case_name" => item.fetch("name"), "evaluator" => evaluator,
          "baseline_score" => old_score, "current_score" => new_score,
          "delta" => old_score && new_score ? new_score - old_score : nil, "reason" => reason
        }
      end

      def sections
        result = [["#{@run.fetch('suite')} — Evaluation report", {
          "Run" => @run.fetch("id"), "Agent" => @run.fetch("agent"),
          "Suite digest" => @run.fetch("suite_digest"), "Status" => @run.fetch("status"),
          "Started at" => @run.fetch("started_at"), "Finished at" => @run.fetch("finished_at"),
          "Metadata" => @run.fetch("metadata")
        }], ["Summary", @run.fetch("summary")]]
        if comparison
          result << ["Baseline comparison", {
            "Baseline run" => comparison.fetch("baseline_id"), "Regressed" => comparison.fetch("regressed"),
            "Pass rate delta" => comparison.fetch("pass_rate_delta"), "Score delta" => comparison.fetch("score_delta"),
            "Regressions" => comparison.fetch("regressions"), "Improvements" => comparison.fetch("improvements")
          }]
        end
        @run.fetch("cases").each do |item|
          result << ["Case: #{item.fetch('name')}", {
            "ID" => item.fetch("id"), "Status" => item.fetch("status"),
            "Question" => item["question"], "Expected answer" => item["expected_answer"], "Output" => item["output"],
            "Criteria" => item["criteria"],
            "Expected actions (ordered)" => item["expected_actions"] || "Unavailable — expected actions not specified",
            "Observed actions (ordered)" => item["actions"] || "Unavailable — action instrumentation missing",
            "Response metadata" => item["response_metadata"].nil? ? "Unavailable — response metadata not reported" : item["response_metadata"],
            "Metadata" => item["metadata"], "Duration (ms)" => item["duration_ms"],
            "Input tokens" => item["input_tokens"], "Output tokens" => item["output_tokens"],
            "Cost" => item["cost"], "Error" => item["error"], "Metrics" => item.fetch("metrics")
          }]
        end
        result
      end

      def display_value(value)
        value.is_a?(String) ? value : JSON.pretty_generate(value)
      end

      def html_escape(value)
        CGI.escapeHTML(value.to_s)
      end

      def markdown_escape(value)
        html_escape(value).gsub(/([\\`*_{}\[\]()#+.!|>~-])/) { |character| "\\#{character}" }
      end
    end
  end
end
