# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lantern_resource) do
      add_column :label, :text, null: true
    end
  end
end
