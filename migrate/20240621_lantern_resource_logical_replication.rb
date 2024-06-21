# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:lantern_resource) do
      add_column :logical_replication, :bool, default: false
    end
  end
end
