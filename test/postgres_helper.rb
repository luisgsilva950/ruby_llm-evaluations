# frozen_string_literal: true

require "pg"
require "uri"
require "securerandom"
require "active_record"

# Tests use the ordinary host pool, isolated by schema, never a developer's tables.
class PostgresSandbox
  DEFAULT_URL = "postgresql://postgres@127.0.0.1:55432/ruby_llm_evaluations_test"
  attr_reader :database_url

  def initialize(migrate: true)
    @previous = ActiveRecord::Base.connection_db_config if ActiveRecord::Base.connection_handler.retrieve_connection_pool(ActiveRecord::Base.connection_specification_name)
    url = ENV.fetch("TEST_DATABASE_URL", DEFAULT_URL)
    @admin = PG.connect(url)
    @schema = "eval_test_#{SecureRandom.hex(12)}"
    @admin.exec("CREATE SCHEMA #{PG::Connection.quote_ident(@schema)}")
    scoped = URI.parse(url)
    query = URI.decode_www_form(scoped.query.to_s).reject { |key, _| key == "schema_search_path" }
    scoped.query = URI.encode_www_form(query + [["schema_search_path", @schema]])
    @database_url = scoped.to_s
    ActiveRecord::Base.establish_connection(@database_url)
    RubyLLM::Evaluations.migrate! if migrate
    [RubyLLM::Evaluations::Run, RubyLLM::Evaluations::CaseResult, RubyLLM::Evaluations::MetricResult].each(&:reset_column_information) if migrate
  rescue StandardError
    close
    raise
  end

  def close
    return unless @admin
    ActiveRecord::Base.remove_connection
    ActiveRecord::Base.establish_connection(@previous) if @previous
    @admin.exec("DROP SCHEMA #{PG::Connection.quote_ident(@schema)} CASCADE") if @schema && !@admin.finished?
  ensure
    @admin&.close unless @admin&.finished?
    @admin = nil
  end
end
