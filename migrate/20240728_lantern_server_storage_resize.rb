# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table(:lantern_server) do
      add_column :max_storage_autoresize_gib, Integer, default: 0
    end
    run "UPDATE lantern_doctor_query SET schedule='*/2 * * * *' WHERE id='09b1b1d1-7095-89b7-8ae4-158e15e11871'"
  end
end
