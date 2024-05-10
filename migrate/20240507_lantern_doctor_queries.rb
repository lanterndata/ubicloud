# frozen_string_literal: true

Sequel.migration do
  up do
    # invalid indexes that still accept inserts
    sql = <<SQL
SELECT i.relname::text
FROM pg_class t
JOIN pg_index ix ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_am a ON i.relam = a.oid
JOIN pg_namespace n ON n.oid = i.relnamespace
WHERE a.amname = 'lantern_hnsw' AND indisready = true AND indisvalid = false;
SQL
    DB[:lantern_doctor_query].insert(
      id: "ae2bb621-179b-81b7-912f-f86de47a0ec1",
      name: "Lantern Invalid Indexes",
      db_name: "*",
      schedule: "20 */2 * * *",
      condition: "unknown",
      sql: sql,
      type: "system",
      response_type: "rows",
      severity: "warning"
    )
    # failed RINDEX CONCURRENTLY indexes
    sql = "SELECT indexname FROM pg_indexes WHERE indexname LIKE '%_ccnew';"

    DB[:lantern_doctor_query].insert(
      id: "2aa8b3ee-4145-85b7-9c8b-4e485caf93d8",
      name: "Failed REINDEX CONCURRENTLY Indexes",
      db_name: "*",
      schedule: "30 */2 * * *",
      condition: "unknown",
      sql: sql,
      type: "system",
      response_type: "rows",
      severity: "info"
    )

    # check if index is is bigger than shared_buffers
    sql = <<SQL
WITH idx_size AS (SELECT coalesce(sum(pg_relation_size(i.relname::text)), 0) AS size
FROM pg_class t
JOIN pg_index ix ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_am a ON i.relam = a.oid
JOIN pg_namespace n ON n.oid = i.relnamespace
WHERE a.amname = 'lantern_hnsw')
SELECT idx_size.size::bigint > setting::bigint * 8196 FROM idx_size, pg_settings WHERE name = 'shared_buffers';
SQL
    DB[:lantern_doctor_query].insert(
      id: "98c0d832-90ea-85b7-9ba5-7c8e1da653ce",
      name: "Index Size vs Shared Buffers",
      db_name: "*",
      schedule: "35 */3 * * *",
      condition: "unknown",
      sql: sql,
      type: "system",
      response_type: "bool",
      severity: "info"
    )

    # check if there are any queries blocked for more than 5m
    sql = <<SQL
    WITH blocked as (
	SELECT pid, pg_blocking_pids(pid) AS blocked_by
          FROM pg_stat_activity WHERE state in ('idle', 'active') AND EXTRACT(EPOCH FROM (now() - query_start)) >= 300 AND cardinality(pg_blocking_pids(pid)) > 0
)
SELECT b.pid,
       usename,
       pg_blocking_pids(b.pid) AS blocked_by,
       query
FROM blocked JOIN pg_stat_activity b ON b.pid = blocked.pid OR b.pid = ANY(blocked.blocked_by)
SQL
    DB[:lantern_doctor_query].insert(
      id: "b5016c82-ba4f-8db7-a0fc-ff5c1b2817da",
      name: "Blocking queries",
      db_name: "*",
      schedule: "*/2 * * * *",
      condition: "unknown",
      sql: sql,
      type: "system",
      response_type: "rows",
      severity: "info"
    )

    # Create semaphores for all lantern doctors to sync system queries
    run "INSERT INTO semaphore (id, strand_id, name) SELECT gen_random_uuid(), id, 'sync_system_queries' FROM strand s WHERE s.prog = 'Lantern::LanternDoctorNexus'"
  end
end
