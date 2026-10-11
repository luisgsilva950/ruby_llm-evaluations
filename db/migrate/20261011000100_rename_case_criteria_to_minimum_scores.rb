# frozen_string_literal: true

class RenameCaseCriteriaToMinimumScores < ActiveRecord::Migration[7.1]
  def change
    rename_column :ruby_llm_evaluations_case_results, :criteria, :minimum_scores
  end
end
