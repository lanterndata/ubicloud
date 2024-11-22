# frozen_string_literal: true

require "uri"
require_relative "../../model"

class LanternResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :forks, key: :parent_id, class: self
  one_to_many :servers, class: LanternServer, key: :resource_id
  one_to_one :representative_server, class: LanternServer, key: :resource_id, conditions: Sequel.~(representative_at: nil)
  one_through_one :timeline, class: LanternTimeline, join_table: :lantern_server, left_key: :resource_id, right_key: :timeline_id
  one_to_one :doctor, class: LanternDoctor, key: :id, primary_key: :doctor_id

  dataset_module Authorization::Dataset
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include DisplayStatusMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy, :swap_leaders_with_parent, :switchover_with_parent, :rollback_switchover

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :db_user_password
    enc.column :repl_password
    enc.column :gcp_creds_b64
  end

  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def big_query_table
    "#{name}_logs"
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/lantern/#{name}"
  end

  def path
    "/location/#{location}/lantern/#{name}"
  end

  def label
    (!super.nil? && !super.empty?) ? super : "no-label"
  end

  def display_state
    return "failover" if servers.find { _1.display_state == "failover" }
    super || representative_server&.display_state || "unavailable"
  end

  def connection_string(port: 6432)
    representative_server&.connection_string(port: port)
  end

  def required_standby_count
    required_standby_count_map = {HaType::NONE => 0, HaType::ASYNC => 1, HaType::SYNC => 2}
    required_standby_count_map[ha_type]
  end

  def dissociate_forks
    forks.each {
      _1.update(parent_id: nil)
      _1.timeline.update(parent_id: nil)
    }
  end

  def setup_service_account
    api = Hosting::GcpApis.new
    service_account = api.create_service_account("lt-#{ubid}", "Service Account for Lantern #{name}")
    update(service_account_name: service_account["email"])
  end

  def export_service_account_key
    api = Hosting::GcpApis.new
    key = api.export_service_account_key(service_account_name)
    update(gcp_creds_b64: key)
  end

  def allow_timeline_access_to_bucket
    timeline.update(gcp_creds_b64: gcp_creds_b64)
    api = Hosting::GcpApis.new
    api.allow_bucket_usage_by_prefix(service_account_name, Config.lantern_backup_bucket, timeline.ubid)
  end

  def set_to_readonly(status: "on")
    representative_server.run_query("
      ALTER SYSTEM SET default_transaction_read_only TO #{status};
      SELECT pg_reload_conf();
    ")
  end

  def create_logical_replication_slot(name)
    representative_server.run_query("SELECT lsn FROM pg_create_logical_replication_slot('#{name}', 'pgoutput');").chomp.strip
  end

  def create_physical_replication_slot(name)
    representative_server.run_query("SELECT lsn FROM pg_create_physical_replication_slot('#{name}', true);").chomp.strip
  end

  def delete_replication_slot(name)
    representative_server.run_query("SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name='#{name}';")
  end

  def get_logical_replication_lag(slot_name)
    representative_server.run_query("SELECT (pg_current_wal_lsn() - confirmed_flush_lsn) FROM pg_catalog.pg_replication_slots WHERE slot_name = '#{slot_name}'").chomp.to_i
  end

  def create_ddl_log
    commands = <<SQL
    BEGIN;
    CREATE TABLE IF NOT EXISTS ddl_log(
        id SERIAL PRIMARY KEY,
        object_tag TEXT,
        ddl_command TEXT,
        timestamp TIMESTAMP,
        "session_user" TEXT
    );
    CREATE OR REPLACE FUNCTION log_ddl_changes()
    RETURNS event_trigger AS $$
    BEGIN
      INSERT INTO ddl_log (object_tag, ddl_command, timestamp, "session_user")
              VALUES (tg_tag, current_query(), current_timestamp, session_user);
    END;
    $$ LANGUAGE plpgsql
    SECURITY DEFINER;

    DROP EVENT TRIGGER IF EXISTS log_ddl_trigger;
    CREATE EVENT TRIGGER log_ddl_trigger
    ON ddl_command_end
    EXECUTE FUNCTION log_ddl_changes();
    COMMIT;
SQL
    representative_server.run_query_all(commands)
  end

  def drop_ddl_log_trigger
    commands = <<SQL
   DROP EVENT TRIGGER IF EXISTS log_ddl_trigger;
SQL
    representative_server.run_query_all(commands)
  end

  def listen_ddl_log
    commands = <<SQL
   DROP EVENT TRIGGER IF EXISTS log_ddl_trigger;
   TRUNCATE TABLE ddl_log RESTART IDENTITY;
   CREATE OR REPLACE FUNCTION execute_ddl_command()
   RETURNS TRIGGER AS $$
   BEGIN
       SET search_path TO public;
       EXECUTE format('SET ROLE %I', NEW.session_user);
       EXECUTE NEW.ddl_command;
       RESET ROLE;
       RETURN NEW;
   END;
   $$ LANGUAGE plpgsql;

   DROP TRIGGER IF EXISTS execute_ddl_after_insert ON ddl_log;
   CREATE TRIGGER execute_ddl_after_insert
   AFTER INSERT ON ddl_log
   FOR EACH ROW
   EXECUTE FUNCTION execute_ddl_command();
   ALTER TABLE ddl_log ENABLE REPLICA TRIGGER execute_ddl_after_insert;
SQL
    representative_server.run_query_all(commands)
  end

  def drop_ddl_log
    commands = <<SQL
   DROP EVENT TRIGGER IF EXISTS log_ddl_trigger;
   DROP TABLE IF EXISTS ddl_log;
   DROP FUNCTION IF EXISTS execute_ddl_command();
SQL
    representative_server.run_query_all(commands)
  end

  def create_publication(name)
    representative_server.run_query_all("CREATE PUBLICATION #{name} FOR ALL TABLES")
  end

  def delete_publication(name)
    representative_server.run_query_all("DROP PUBLICATION IF EXISTS #{name}")
  end

  def sync_sequences_with_parent
    representative_server.list_all_databases.each do |db|
      res = parent.representative_server.run_query("
        SELECT sequence_schema, sequence_name, last_value
    FROM information_schema.sequences
    JOIN pg_sequences
    ON (information_schema.sequences.sequence_schema = pg_sequences.schemaname
    AND information_schema.sequences.sequence_name = pg_sequences.sequencename)
    WHERE last_value > 0;", db: db)

      statements = res.chomp.strip.split("\n").map do |row|
        values = row.split(",")
        "SELECT setval('#{values[0]}.#{values[1]}', #{values[2]});"
      end

      representative_server.run_query(statements.join("\n"), db: db)
    end
  end

  def create_and_enable_subscription
    representative_server.list_all_databases.each do |db|
      uri = URI.parse(parent.connection_string(port: 5432))
      new_query_ar = URI.decode_www_form(String(uri.query)) << ["dbname", db]
      uri.query = URI.encode_www_form(new_query_ar)
      commands = <<SQL
      CREATE SUBSCRIPTION sub_#{ubid}
      CONNECTION '#{uri}'
      PUBLICATION pub_#{ubid}
      WITH (
        copy_data = false,
        create_slot = false,
        binary = true,
        enabled = true,
        synchronous_commit = false,
        connect = true,
        slot_name = 'slot_#{ubid}'
      );
SQL
      representative_server.run_query(commands, db: db)
    end
  end

  def delete_logical_subscription(name)
    commands = <<SQL
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_subscription WHERE subname='#{name}') THEN
      ALTER SUBSCRIPTION #{name} DISABLE;
      ALTER SUBSCRIPTION #{name} SET (slot_name=NONE);
      DROP SUBSCRIPTION #{name};
    END IF;
END
$$;
SQL
    representative_server.run_query_all(commands)
  end

  def mark_switchover_start
    commands = <<SQL
   BEGIN;
   DROP TABLE IF EXISTS _ldb_switchover_info;
   CREATE TABLE _ldb_switchover_info(
     id SERIAL PRIMARY KEY,
     started_at TIMESTAMP NOT NULL DEFAULT NOW(),
     finished_at TIMESTAMP
   );
   INSERT INTO _ldb_switchover_info(started_at) VALUES (NOW());
   COMMIT;
SQL
    representative_server.run_query(commands)
  end

  def mark_switchover_finish
    representative_server.run_query("UPDATE _ldb_switchover_info SET finished_at=NOW()")
  end

  def create_logical_replica(resource_name: nil, lantern_version: nil, extras_version: nil, minor_version: nil, pg_upgrade: nil)
    # TODO::
    # 1. If new database will be created during logical replication it won't be added automatically
    ubid = LanternResource.generate_ubid
    create_ddl_log
    create_publication("pub_#{ubid}")
    slot_lsn = create_logical_replication_slot("slot_#{ubid}")
    Prog::Lantern::LanternResourceNexus.assemble(
      project_id: project_id,
      location: location,
      name: resource_name || "#{name}-#{Time.now.to_i}",
      label: "#{label}-logical",
      ubid: ubid,
      target_vm_size: representative_server.target_vm_size,
      target_storage_size_gib: representative_server.target_storage_size_gib,
      parent_id: id,
      restore_target: timeline.latest_restore_time.utc.to_s[..-5],
      recovery_target_lsn: slot_lsn,
      org_id: org_id,
      version_upgrade: true,
      logical_replication: true,
      lantern_version: lantern_version || representative_server.lantern_version,
      extras_version: extras_version || representative_server.extras_version,
      minor_version: minor_version || representative_server.minor_version,
      pg_version: pg_version,
      pg_upgrade: pg_upgrade
    )
  end

  def create_logging_table
    api = Hosting::GcpApis.new
    schema = [
      {name: "log_time", type: "TIMESTAMP", mode: "NULLABLE"},
      {name: "user_name", type: "STRING", mode: "NULLABLE"},
      {name: "database_name", type: "STRING", mode: "NULLABLE"},
      {name: "process_id", type: "INTEGER", mode: "NULLABLE"},
      {name: "connection_from", type: "STRING", mode: "NULLABLE"},
      {name: "session_id", type: "STRING", mode: "NULLABLE"},
      {name: "session_line_num", type: "INTEGER", mode: "NULLABLE"},
      {name: "command_tag", type: "STRING", mode: "NULLABLE"},
      {name: "session_start_time", type: "TIMESTAMP", mode: "NULLABLE"},
      {name: "virtual_transaction_id", type: "STRING", mode: "NULLABLE"},
      {name: "transaction_id", type: "INTEGER", mode: "NULLABLE"},
      {name: "error_severity", type: "STRING", mode: "NULLABLE"},
      {name: "sql_state_code", type: "STRING", mode: "NULLABLE"},
      {name: "duration", type: "FLOAT", mode: "NULLABLE"},
      {name: "message", type: "STRING", mode: "NULLABLE"},
      {name: "detail", type: "STRING", mode: "NULLABLE"},
      {name: "hint", type: "STRING", mode: "NULLABLE"},
      {name: "internal_query", type: "STRING", mode: "NULLABLE"},
      {name: "internal_query_pos", type: "INTEGER", mode: "NULLABLE"},
      {name: "context", type: "STRING", mode: "NULLABLE"},
      {name: "query", type: "STRING", mode: "NULLABLE"},
      {name: "query_pos", type: "INTEGER", mode: "NULLABLE"},
      {name: "location", type: "STRING", mode: "NULLABLE"},
      {name: "application_name", type: "STRING", mode: "NULLABLE"}
    ]
    api.create_big_query_table(Config.lantern_log_dataset, big_query_table, schema)
  end

  def allow_big_query_access
    api = Hosting::GcpApis.new
    # Add metadata viewer access
    api.allow_access_to_big_query_dataset(service_account_name, Config.lantern_log_dataset)
    # Add access to only this table
    api.allow_access_to_big_query_table(service_account_name, Config.lantern_log_dataset, big_query_table)
  end

  module HaType
    NONE = "none"
    ASYNC = "async"
    SYNC = "sync"
  end

  def prepare_switchover(force = false)
    if parent.nil? || !logical_replication
      fail "Database does not have parent or is not in logical replication state"
    end

    if !force
      err = ""
      replica_dbs = representative_server.list_all_databases
      parent_dbs = parent.representative_server.list_all_databases
      db_diff = parent_dbs - replica_dbs

      if db_diff.any?
        err = "The following databases were not synced to replica: #{db_diff.join(",")}\n"
      end

      replica_roles = representative_server.list_all_roles
      parent_roles = parent.representative_server.list_all_roles
      roles_diff = parent_roles - replica_roles

      if roles_diff.any?
        err = "#{err}The following roles were not synced to replica: #{roles_diff.join(",")}\n"
      end

      lo_count_replica = representative_server.run_query("SELECT COUNT(*) FROM pg_largeobject_metadata")
      lo_count_parent = parent.representative_server.run_query("SELECT COUNT(*) FROM pg_largeobject_metadata")
      lo_diff = lo_count_parent.to_i - lo_count_replica.to_i

      if lo_diff > 0
        err = "#{err}Parent database has #{lo_diff} more large objects than replica\n"
      end

      if !err.empty?
        err = "Inconsistencies found between parent and replica databases.\nPlease synchronize databases manually or create new replica or pass force=true if you are sure you want to switchover\n#{err}"
        fail err
      end
    else
      current_frame = strand.stack.first
      current_frame["force_switchover"] = true
      strand.modified!(:stack)
      strand.save_changes
    end

    incr_switchover_with_parent
  end

  def rollback_switchover
    current_resource = LanternResource[rollback_target]
    # stop current one and start old one
    begin
      current_resource.representative_server.stop_container(1)
    rescue
    end
    current_resource.representative_server.incr_container_stopped

    representative_server.incr_take_over

    # update dns
    cf_client = Dns::Cloudflare.new
    cf_client.upsert_dns_record(current_resource.representative_server.domain, representative_server.vm.sshable.host)
    representative_server.update(domain: current_resource.representative_server.domain)
    current_resource.representative_server.update(domain: nil)

    update(rollback_target: nil)
  end
end
