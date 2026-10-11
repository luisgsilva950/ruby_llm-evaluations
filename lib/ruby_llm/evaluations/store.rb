# frozen_string_literal: true

require "active_record"
require "pg"
require "securerandom"
require "thread"
require "time"
require "uri"
require_relative "data"

module RubyLLM
  module Evaluations
    class Store
      SCHEMA_VERSION = 1
      RUNS_TABLE = "ruby_llm_evaluations_runs"
      VERSIONS_TABLE = "ruby_llm_evaluations_schema_versions"

      def initialize(connection = ENV.fetch("DATABASE_URL", DEFAULT_DATABASE_URL))
        @mutex = Mutex.new
        validate_connection!(connection)
        @model_name = "Connection#{SecureRandom.hex(16)}"
        @model = self.class.const_set(@model_name, Class.new(::ActiveRecord::Base))
        @model.table_name = RUNS_TABLE
        @model.primary_key = "sequence"
        @model.establish_connection(connection)
        @model.connection_pool.with_connection do |database|
          raise ArgumentError, "history requires PostgreSQL" unless database.adapter_name == "PostgreSQL"
          migrate!(database)
        end
      rescue ::ActiveRecord::ActiveRecordError, PG::Error
        close
        raise Error, "cannot initialize PostgreSQL history", cause: nil
      rescue StandardError
        close
        raise
      end

      # INSERT-only: no update/upsert path can replace historical evidence.
      def save(run)
        value = Data.json_value(run)
        %w[id suite agent suite_digest started_at].each do |key|
          unless value[key].is_a?(String) && !value[key].empty?
            raise ArgumentError, "run #{key} must be a nonempty string"
          end
        end
        raise ArgumentError, "only completed runs can be saved" unless value["status"] == "completed"
        timestamp = Time.iso8601(value.fetch("started_at")).utc
        synchronize do
          @model.transaction do
            @model.create!(value.slice("suite", "agent", "suite_digest").merge(
              "run_id" => value.fetch("id"), "started_at" => timestamp, "payload" => value
            ))
          end
        end
        value
      rescue ::ActiveRecord::RecordNotUnique
        raise Error, "run cannot replace existing history", cause: nil
      end

      def find(id)
        synchronize { @model.where(run_id: id).pick(:payload) }
      end

      def list(suite: nil, agent: nil, limit: 100)
        unless limit.is_a?(Integer) && limit >= 0
          raise ArgumentError, "limit must be a nonnegative integer"
        end
        synchronize do
          query = @model.all
          query = query.where(suite: suite) unless suite.nil?
          query = query.where(agent: agent) unless agent.nil?
          query.order(started_at: :desc, sequence: :desc).limit(limit).pluck(:payload)
        end
      end

      def latest(suite:, agent:, suite_digest:, before_id: nil)
        synchronize do
          query = @model.where(suite: suite, agent: agent, suite_digest: suite_digest)
          unless before_id.nil?
            previous = @model.where(run_id: before_id).pick(:started_at, :sequence)
            return nil unless previous
            query = query.where("started_at < ? OR (started_at = ? AND sequence < ?)",
                                previous[0], previous[0], previous[1])
          end
          query.order(started_at: :desc, sequence: :desc).pick(:payload)
        end
      end

      def close
        @mutex.synchronize do
          if @model
            @model.remove_connection
            self.class.send(:remove_const, @model_name)
            @model = nil
          end
        end
        nil
      end

      private

      def validate_connection!(connection)
        adapter = if connection.is_a?(Hash)
                    connection[:adapter] || connection["adapter"]
                  elsif connection.is_a?(String)
                    URI.parse(connection).scheme
                  end
        unless %w[postgresql postgres].include?(adapter.to_s)
          raise ArgumentError, "history requires a PostgreSQL URL or ActiveRecord configuration"
        end
      rescue URI::InvalidURIError
        raise ArgumentError, "history requires a valid PostgreSQL URL", cause: nil
      end

      def synchronize
        @mutex.synchronize do
          raise Error, "store is closed" unless @model
          @model.connection_pool.with_connection { yield }
        end
      end

      def migrate!(database)
        database.transaction do
          # A transaction-scoped database lock serializes even first-time DDL across pools.
          database.execute("SELECT pg_advisory_xact_lock(728194620113)")
          unless database.table_exists?(VERSIONS_TABLE)
            if database.table_exists?(RUNS_TABLE)
              raise Error, "history schema is missing its version"
            end
            database.create_table(VERSIONS_TABLE, id: false) { |table| table.integer :version, null: false, primary_key: true }
          end
          versions = database.select_values("SELECT version FROM #{VERSIONS_TABLE}").map(&:to_i)
          unless versions.empty? || versions == [SCHEMA_VERSION]
            raise Error, "unsupported history schema version"
          end
          if versions.empty?
            raise Error, "history schema is missing its version" if database.table_exists?(RUNS_TABLE)
            database.create_table(RUNS_TABLE, primary_key: :sequence) do |table|
              table.text :run_id, null: false
              table.text :suite, null: false
              table.text :agent, null: false
              table.text :suite_digest, null: false
              table.column :started_at, :timestamptz, null: false, precision: 6
              table.jsonb :payload, null: false
            end
            database.add_index(RUNS_TABLE, :run_id, unique: true)
            [[], [:suite], [:agent], [:suite, :agent, :suite_digest]].each_with_index do |prefix, index|
              database.add_index(RUNS_TABLE, prefix + [:started_at, :sequence],
                                 order: { started_at: :desc, sequence: :desc }, name: "rle_history_#{index}")
            end
            database.execute("INSERT INTO #{VERSIONS_TABLE} (version) VALUES (#{SCHEMA_VERSION})")
          elsif !database.table_exists?(RUNS_TABLE)
            raise Error, "history schema is missing its runs table"
          end
        end
      end
    end
  end
end
