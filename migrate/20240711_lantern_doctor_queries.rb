# frozen_string_literal: true

Sequel.migration do
  up do
    # check duplicate sources for embedding jobs
    run "INSERT INTO lantern_doctor_query (id, name, db_name, schedule, condition, fn_label, type, severity, response_type)
         VALUES ('09f5de22-13fb-89b7-bf5e-75b26faef139', 'Whitespace tokens for embedding job', '*', '*/8 * * * *', 'unknown', 'check_embedding_source_whitespaces', 'system', 'error', 'rows')"

    # Create semaphores for all lantern doctors to sync system queries
    run "INSERT INTO semaphore (id, strand_id, name) SELECT gen_random_uuid(), id, 'sync_system_queries' FROM strand s WHERE s.prog = 'Lantern::LanternDoctorNexus'"
  end
end
