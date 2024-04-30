# frozen_string_literal: true

Sequel.migration do
  change do
    create_enum(:severity, %w[critical error warning info])
    alter_table(:page) do
      add_column :severity, :severity, default: "error", null: false
    end
  end
end
