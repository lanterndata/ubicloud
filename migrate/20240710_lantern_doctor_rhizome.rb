# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:lantern_doctor_page) do
      add_column :vm_name, :text, null: true
    end

    alter_table(:lantern_doctor_query) do
      add_column :server_type, :text, null: true, default: "primary"
    end

    # this is the query to check disk size, it should run on all servers
    run "UPDATE lantern_doctor_query SET server_type='*' WHERE id='09b1b1d1-7095-89b7-8ae4-158e15e11871'"

    # update queries to sync rhizome
    run "INSERT INTO semaphore (id, strand_id, name) SELECT gen_random_uuid(), id, 'sync_system_queries' FROM strand s WHERE s.prog = 'Lantern::LanternDoctorNexus'"
  end
end
