# frozen_string_literal: true

Sequel.migration do
  up do
    # check duplicate sources for embedding jobs
    run "INSERT INTO lantern_doctor_query (id, name, db_name, schedule, condition, fn_label, type, severity, response_type)
         VALUES ('0e5fab85-71f6-89b7-96cf-f1e8e1074389', 'Cleanup dangling docker images', 'postgres', '0 9 * * *', 'unknown', 'remove_dangling_images', 'system', 'error', 'rows')"

    # Create semaphores for all lantern doctors to sync system queries
    run "INSERT INTO semaphore (id, strand_id, name) SELECT gen_random_uuid(), id, 'sync_system_queries' FROM strand s WHERE s.prog = 'Lantern::LanternDoctorNexus'"
  end
end
