# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:lantern_resource) do
      add_column :recovery_target_lsn, :text, collate: '"C"'
      add_column :version_upgrade, :bool, default: false
    end
  end
end
