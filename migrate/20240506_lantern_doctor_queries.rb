# frozen_string_literal: true

Sequel.migration do
  change do
    run "INSERT INTO lantern_doctor_query (id, name, db_name, schedule, condition, fn_label, type, severity)
         VALUES ('4f916f44-3c7a-89b7-9795-1ccd417b45ba', 'Check Daemon Embedding Job', '*', '*/5 * * * *', 'unknown', 'check_daemon_embedding_jobs', 'system', 'error')"
  end
end
