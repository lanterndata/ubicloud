# frozen_string_literal: true

Sequel.migration do
  up do
    # percent toward transaction wraparound
    sql = <<SQL
 SELECT 2000000000 as max_old_xid,
        setting AS autovacuum_freeze_max_age
        FROM pg_catalog.pg_settings
        WHERE name = 'autovacuum_freeze_max_age')
, per_database_stats AS (
    SELECT datname
        , m.max_old_xid::int
        , m.autovacuum_freeze_max_age::int
        , age(d.datfrozenxid) AS oldest_current_xid
    FROM pg_catalog.pg_database d
    JOIN max_age m ON (true)
    WHERE d.datallowconn )
SELECT max(ROUND(100*(oldest_current_xid/max_old_xid::float))) > 85 FROM per_database_stats;
SQL
    DB[:lantern_doctor_query].insert(
      id: "98cf148c-a88c-85b7-9bec-dbc912b022be",
      name: "Percent towards tx wraparound is >85%",
      db_name: "postgres",
      schedule: "45 */10 * * *",
      condition: "unknown",
      sql: sql,
      type: "system",
      response_type: "bool",
      severity: "warning"
    )
  end
end
