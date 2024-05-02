# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lantern_resource) do
      add_column :display_state, :text, null: true
    end
  end
end
