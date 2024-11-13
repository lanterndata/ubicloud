# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lantern_resource) do
      add_column :rollback_target, :uuid
    end
  end
end
