# frozen_string_literal: true

require "net/ssh"
require_relative "../../model"

class LanternServer < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :gcp_vm, key: :id, primary_key: :vm_id
  many_to_one :resource, class: LanternResource, key: :resource_id
  many_to_one :timeline, class: LanternTimeline, key: :timeline_id

  dataset_module Authorization::Dataset
  dataset_module Pagination

  include HealthMonitorMethods
  include ResourceMethods
  include SemaphoreMethods

  semaphore :initial_provisioning, :update_user_password, :update_lantern_extension, :update_extras_extension, :update_image, :setup_ssl, :add_domain, :update_rhizome, :checkup
  semaphore :start_server, :stop_server, :restart_server, :take_over, :destroy, :update_storage_size, :update_vm_size, :update_memory_limits, :init_sql, :restart

  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def vm
    gcp_vm
  end

  def hostname
    if domain
      return domain
    end

    return nil unless vm.sshable.host && !vm.sshable.host.start_with?("temp")

    vm.sshable.host
  end

  def connection_string
    return nil unless (hn = hostname)
    URI::Generic.build2(
      scheme: "postgres",
      userinfo: "postgres:#{URI.encode_uri_component(resource.superuser_password)}",
      host: hn,
      port: 6432
    ).to_s
  end

  def run_query(query, db: "postgres", user: "postgres")
    vm.sshable.cmd("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -q -U #{user} -t --csv #{db}", stdin: query).chomp
  end

  def run_query_all(query)
    list_all_databases.map { [_1, run_query(query, db: _1)] }
  end

  def display_state
    return "deleting" if destroy_set? || strand.label == "destroy"
    return "stopped" if vm.display_state == "stopped"
    return "stopping" if vm.display_state == "stopping"
    return "starting" if vm.display_state == "starting"
    return "failed" if vm.display_state == "failed"
    return "domain setup" if strand.label.include?("domain")
    return "ssl setup" if strand.label == "setup_ssl"
    return "updating" if strand.label.include?("update")
    return "updating" if strand.label == "init_sql"
    return "unavailable" if strand.label == "wait_db_available"
    return "running" if strand.label == "wait"
    "creating"
  end

  def primary?
    timeline_access == "push"
  end

  def standby?
    timeline_access == "fetch" && !doing_pitr?
  end

  def doing_pitr?
    !resource.representative_server.primary?
  end

  def instance_type
    standby? ? "reader" : "writer"
  end

  def configure_hash
    walg_config = timeline.generate_walg_config
    backup_label = ""

    # Set backup_label if the database is being initialized from backup
    if !resource.parent.nil?
      backup_label = if standby? || resource.restore_target.nil?
        "LATEST"
      else
        timeline.latest_backup_label_before_target(resource.restore_target)
      end
    end

    JSON.generate({
      enable_coredumps: true,
      org_id: resource.org_id,
      instance_id: resource.name,
      instance_type: instance_type,
      app_env: resource.app_env,
      enable_debug: resource.debug,
      enable_telemetry: resource.enable_telemetry || "",
      repl_user: resource.repl_user || "",
      repl_password: resource.repl_password || "",
      replication_mode: standby? ? "slave" : "master",
      db_name: resource.db_name || "",
      db_user: resource.db_user || "",
      db_user_password: resource.db_user_password || "",
      postgres_password: resource.superuser_password || "",
      # master_host: lantern_server.master_host,
      # master_port: lantern_server.master_port,
      prom_password: Config.prom_password,
      gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
      gcp_creds_coredumps_b64: Config.gcp_creds_coredumps_b64,
      gcp_creds_logging_b64: Config.gcp_creds_logging_b64,
      container_image: "#{Config.gcr_image}:lantern-#{lantern_version}-extras-#{extras_version}-minor-#{minor_version}",
      postgresql_recover_from_backup: backup_label,
      postgresql_recovery_target_time: resource.restore_target || "",
      gcp_creds_walg_b64: walg_config[:gcp_creds_b64],
      walg_gs_prefix: walg_config[:walg_gs_prefix]
    })
  end

  def update_walg_creds
    walg_config = timeline.generate_walg_config
    vm.sshable.cmd("sudo lantern/bin/update_env", stdin: JSON.generate([
      ["WALG_GS_PREFIX", walg_config[:walg_gs_prefix]],
      ["GOOGLE_APPLICATION_CREDENTIALS_WALG_B64", walg_config[:gcp_creds_b64]],
      ["POSTGRESQL_RECOVER_FROM_BACKUP", ""]
    ]))
  end

  def container_image
    "#{Config.gcr_image}:lantern-#{lantern_version}-extras-#{extras_version}-minor-#{minor_version}"
  end

  def init_health_monitor_session
    if strand.label != "wait"
      fail "server is not ready to initialize session"
    end

    {
      db_connection: nil
    }
  end

  def check_pulse(session:, previous_pulse:)
    if destroy_set? || strand&.label != "wait" || display_state != "running"
      # if there's an operation ongoing, do not check the pulse
      return previous_pulse
    end

    reading = begin
      session[:db_connection] ||= Sequel.connect(connection_string)
      lsn_function = primary? ? "pg_current_wal_lsn()" : "pg_last_wal_receive_lsn()"
      last_known_lsn = session[:db_connection]["SELECT #{lsn_function} AS lsn"].first[:lsn]
      "up"
    rescue
      "down"
    end
    pulse = aggregate_readings(previous_pulse: previous_pulse, reading: reading, data: {last_known_lsn: last_known_lsn})

    DB.transaction do
      if pulse[:reading] == "up" && pulse[:reading_rpt] % 12 == 1
        LanternLsnMonitor.new(last_known_lsn: last_known_lsn) { _1.lantern_server_id = id }
          .insert_conflict(
            target: :lantern_server_id,
            update: {last_known_lsn: last_known_lsn}
          ).save_changes
      end

      if pulse[:reading] == "down" && pulse[:reading_rpt] > 5 && Time.now - pulse[:reading_chg] > 30
        incr_checkup
      end
    end

    pulse
  end

  def prewarm_indexes_query
    <<SQL
    SELECT i.relname, pg_prewarm(i.relname::text)
FROM pg_class t
JOIN pg_index ix ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_am a ON i.relam = a.oid
JOIN pg_namespace n ON n.oid = i.relnamespace
WHERE a.amname = 'lantern_hnsw';
SQL
  end

  def list_all_databases
    vm.sshable.cmd("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec postgresql psql -U postgres -P \"footer=off\" -c 'SELECT datname from pg_database' | tail -n +3 | grep -v 'template0' | grep -v 'template1'")
      .chomp
      .strip
      .split("\n")
      .map { _1.strip }
  end

  # def failover_target
  #   nil
  # end
end
