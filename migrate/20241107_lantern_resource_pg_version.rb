# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lantern_resource) do
      add_column :pg_version, Integer, default: 17
    end
    run "UPDATE lantern_resource SET pg_version=15"
  end
end
