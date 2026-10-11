# frozen_string_literal: true

require "pg"
require "uri"
require "securerandom"

# Every test owns an isolated PostgreSQL schema; never erase a developer database.
class PostgresSandbox
  DEFAULT_URL = "postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations_test"
  attr_reader :database_url

  def initialize
    url = ENV.fetch("TEST_DATABASE_URL", DEFAULT_URL)
    @admin = PG.connect(url)
    @schema = "eval_test_#{SecureRandom.hex(12)}"
    @admin.exec("CREATE SCHEMA #{PG::Connection.quote_ident(@schema)}")
    scoped = URI.parse(url)
    query = URI.decode_www_form(scoped.query.to_s).reject { |key, _| key == "schema_search_path" }
    scoped.query = URI.encode_www_form(query + [["schema_search_path", @schema]])
    @database_url = scoped.to_s
  rescue StandardError
    @admin&.close
    raise
  end

  def close
    return unless @admin && !@admin.finished?
    @admin.exec("DROP SCHEMA #{PG::Connection.quote_ident(@schema)} CASCADE") if @schema
    @admin.close
    @admin = nil
  end
end
