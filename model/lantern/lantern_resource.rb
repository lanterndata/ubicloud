# frozen_string_literal: true

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

  semaphore :destroy, :swap_leaders_with_parent

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
    key = api.export_service_account_key(service_account["email"])
    update(gcp_creds_b64: key, service_account_name: service_account["email"])
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
      SHOW default_transaction_read_only;
    ")
  end

  def create_replication_slot(name)
    representative_server.run_query("SELECT lsn FROM pg_create_logical_replication_slot('#{name}', 'pgoutput');").chomp.strip
  end

  def create_ddl_log
    commands = <<SQL
    BEGIN;
    CREATE TABLE IF NOT EXISTS ddl_log(
        id SERIAL PRIMARY KEY,
        object_tag TEXT,
        ddl_command TEXT,
        timestamp TIMESTAMP
    );
    CREATE OR REPLACE FUNCTION log_ddl_changes()
    RETURNS event_trigger AS $$
    BEGIN
      INSERT INTO ddl_log (object_tag, ddl_command, timestamp)
              VALUES (tg_tag, current_query(), current_timestamp);
    END;
    $$ LANGUAGE plpgsql;

    DROP EVENT TRIGGER IF EXISTS log_ddl_trigger;
    CREATE EVENT TRIGGER log_ddl_trigger
    ON ddl_command_end
    EXECUTE FUNCTION log_ddl_changes();
    COMMIT;
SQL
    representative_server.run_query_all(commands)
  end

  def listen_ddl_log
    commands = <<SQL
   DROP EVENT TRIGGER IF EXISTS log_ddl_trigger;
   CREATE OR REPLACE FUNCTION execute_ddl_command()
   RETURNS TRIGGER AS $$
   BEGIN
       SET search_path TO public;
       EXECUTE NEW.ddl_command;
       RETURN NEW;
   END;
   $$ LANGUAGE plpgsql;

   CREATE TRIGGER execute_ddl_after_insert
   AFTER INSERT ON ddl_log
   FOR EACH ROW
   EXECUTE FUNCTION execute_ddl_command();
SQL
    representative_server.run_query_all(commands)
  end

  def create_publication(name)
    representative_server.run_query_all("CREATE PUBLICATION #{name} FOR ALL TABLES")
  end

  def create_and_enable_subscription
    representative_server.list_all_databases.each do |db|
      commands = <<SQL
      CREATE SUBSCRIPTION sub_#{ubid}
      CONNECTION '#{parent.connection_string(port: 5432)}/#{db}'
      PUBLICATION pub_#{ubid}
      WITH (
        copy_data = false,
        create_slot = false,
        enabled = true,
        synchronous_commit = false,
        connect = true,
        slot_name = 'slot_#{ubid}'
      );
SQL
      representative_server.run_query(commands)
    end
  end

  def disable_logical_subscription
    representative_server.run_query_all("ALTER SUBSCRIPTION sub_#{ubid} DISABLE")
  end

  def create_logical_replica(lantern_version: nil, extras_version: nil, minor_version: nil)
    ubid = LanternResource.generate_ubid
    create_publication("pub_#{ubid}")
    create_ddl_log
    slot_lsn = create_replication_slot("slot_#{ubid}")
    Prog::Lantern::LanternResourceNexus.assemble(
      project_id: project_id,
      location: location,
      name: "#{name}-#{Time.now.to_i}",
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
      minor_version: minor_version || representative_server.minor_version
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
end
