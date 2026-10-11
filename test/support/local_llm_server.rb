# frozen_string_literal: true

require "json"
require "webrick"
require "timeout"

# Scripted transport responses, not a simulation of model reasoning.
class LocalLLMServer
  ANSWER = "You may return the book within thirty days."
  attr_accessor :revision, :judge_failures
  attr_reader :requests

  def initialize
    @revision = :correct
    @judge_failures = []
    @requests = []
    @server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [], RequestTimeout: 5)
    @server.mount_proc("/v1/chat/completions") do |request, response|
      response["Content-Type"] = "application/json"
      if request.request_method != "POST"
        response.status = 405
        response.body = JSON.generate(error: { message: "POST required" })
        next
      end
      payload = JSON.parse(request.body)
      @requests << payload
      if payload.fetch("model") == "fixture-judge"
        failure = @judge_failures.shift
        if failure == :provider
          response.status = 503
          response.body = JSON.generate(error: { message: "fixture judge unavailable", type: "server_error" })
          next
        end
        prompt = payload.fetch("messages").last.fetch("content")
        accuracy = prompt.include?("Score factual semantic agreement")
        content = if failure.is_a?(Hash)
                    JSON.generate(failure)
                  elsif failure == :malformed
                    "not valid JSON"
                  else
                    JSON.generate(score: accuracy ? 0.95 : 1.0,
                      reason: accuracy ? "Equivalent thirty-day return policy." : "Directly addresses the return request.")
                  end
        response.body = completion(payload, { role: "assistant", content: content }, 7, 3)
      elsif payload.fetch("messages").last.fetch("role") == "tool"
        response.body = completion(payload, { role: "assistant", content: ANSWER }, 20, 5)
      else
        calls = [tool_call("lookup", "return_policy", product: @revision == :wrong_arguments ? "pen" : "book")]
        calls << tool_call("extra", "store_hours", {}) if @revision == :extra_action
        response.body = completion(payload, { role: "assistant", content: nil, tool_calls: calls }, 10, 2)
      end
    end
    @thread = Thread.new { @server.start }
    Timeout.timeout(5) { sleep 0.005 until @server.status == :Running }
  rescue StandardError
    close
    raise
  end

  def base_url
    "http://127.0.0.1:#{@server.listeners.first.addr[1]}/v1"
  end

  def close
    @server&.shutdown
    return unless @thread
    raise "local fixture did not stop" unless @thread.join(5)
    @thread.value
    @thread = nil
  end

  private

  def tool_call(id, name, arguments)
    { id: id, type: "function", function: { name: name, arguments: JSON.generate(arguments) } }
  end

  def completion(payload, message, input_tokens, output_tokens)
    JSON.generate(id: "fixture-completion", object: "chat.completion", created: 0,
      model: payload.fetch("model"), choices: [{ index: 0, message: message,
      finish_reason: message[:tool_calls] ? "tool_calls" : "stop" }],
      usage: { prompt_tokens: input_tokens, completion_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens })
  end
end
