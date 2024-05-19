# frozen_string_literal: true

Sequel.migration do
  up do
    # check disk space usage
    run "INSERT INTO lantern_doctor_query (id, name, db_name, schedule, condition, fn_label, type, severity, response_type)
         VALUES ('09b1b1d1-7095-89b7-8ae4-158e15e11871', 'Lantern Server Disk Usage', 'postgres', '*/5 * * * *', 'unknown', 'check_disk_space_usage', 'system', 'error', 'rows')"

    # Create semaphores for all lantern doctors to sync system queries
    run "INSERT INTO semaphore (id, strand_id, name) SELECT gen_random_uuid(), id, 'sync_system_queries' FROM strand s WHERE s.prog = 'Lantern::LanternDoctorNexus'"
  end
end
