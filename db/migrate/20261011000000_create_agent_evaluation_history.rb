# frozen_string_literal: true

class CreateAgentEvaluationHistory < ActiveRecord::Migration[7.1]
  RUNS = "ruby_llm_evaluations_runs"
  CASES = "ruby_llm_evaluations_case_results"
  METRICS = "ruby_llm_evaluations_metric_results"

  def change
    json_type = connection.adapter_name == "PostgreSQL" ? :jsonb : :json
    table_options = connection.adapter_name == "Mysql2" ? { charset: "utf8mb4", collation: "utf8mb4_0900_bin" } : {}

    create_table RUNS, primary_key: :sequence, **table_options do |table|
      table.string :id, null: false
      table.string :suite, null: false
      table.string :agent, null: false
      table.string :version, null: false, default: "1"
      table.string :suite_digest, limit: 64, null: false
      table.datetime :started_at, null: false, precision: 6
      table.datetime :finished_at, null: false, precision: 6
      table.string :status, null: false
      table.column :metadata, json_type, null: false
      table.column :summary, json_type, null: false
      table.timestamps precision: 6
    end
    add_index RUNS, :id, unique: true
    add_index RUNS, [:started_at, :sequence], order: { started_at: :desc, sequence: :desc }, name: "rle_runs_recent"
    add_index RUNS, [:suite, :agent, :suite_digest, :started_at, :sequence],
              order: { started_at: :desc, sequence: :desc }, name: "rle_runs_comparable"

    create_table CASES, **table_options do |table|
      table.references :run, type: :string, null: false, foreign_key: { to_table: RUNS, primary_key: :id }
      table.integer :position, null: false
      table.string :case_id, null: false
      table.text :name, null: false
      table.column :question, json_type
      table.column :expected_answer, json_type
      table.column :expected_actions, json_type
      table.column :minimum_scores, json_type, null: false
      table.column :metadata, json_type, null: false
      table.column :output, json_type
      table.string :status, null: false
      table.float :duration_ms, null: false
      table.bigint :input_tokens
      table.bigint :output_tokens
      table.float :cost
      table.column :actions, json_type
      table.column :response_metadata, json_type
      table.column :error_details, json_type
      table.timestamps precision: 6
    end
    add_index CASES, [:run_id, :position], unique: true, name: "rle_case_order"
    add_index CASES, [:run_id, :case_id], unique: true, name: "rle_case_identity"

    create_table METRICS, **table_options do |table|
      table.references :case_result, null: false, foreign_key: { to_table: CASES }
      table.integer :position, null: false
      table.string :name, null: false
      table.float :threshold, null: false
      table.float :score
      table.boolean :passed, null: false
      table.text :reason
      table.column :error_details, json_type
      table.timestamps precision: 6
    end
    add_index METRICS, [:case_result_id, :position], unique: true, name: "rle_metric_order"
    add_index METRICS, [:case_result_id, :name], unique: true, name: "rle_metric_identity"
  end
end
