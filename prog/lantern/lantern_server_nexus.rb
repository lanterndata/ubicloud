# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Lantern::LanternServerNexus < Prog::Base
  subject_is :lantern_server

  extend Forwardable
  def_delegators :lantern_server, :gcp_vm

  semaphore :initial_provisioning, :update_user_password, :update_lantern_extension, :update_extras_extension, :update_image, :setup_ssl, :add_domain, :update_rhizome, :checkup
  semaphore :start_server, :stop_server, :restart_server, :take_over, :destroy, :update_storage_size, :update_vm_size, :update_memory_limits

  def self.assemble(
    project_id: nil, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "1",
    org_id: nil, name: nil, instance_type: "writer",
    db_name: "postgres", db_user: "postgres", db_user_password: nil,
    location: "us-central1", target_vm_size: nil, storage_size_gib: 50,
    postgres_password: nil, master_host: nil, master_port: nil, domain: nil,
    app_env: Config.rack_env, repl_password: nil, enable_telemetry: Config.production?,
    enable_debug: false, repl_user: "repl_user", timeline_id: nil, restore_target: nil
  )

    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing parent"
      end
      ubid = LanternServer.generate_ubid
      name ||= LanternServer.ubid_to_name(ubid)
      repl_password ||= SecureRandom.urlsafe_base64(15)
      enable_debug ||= false
      repl_user ||= "repl_user"

      Validation.validate_name(name)
      if db_user
        Validation.validate_name(db_user)
      else
        db_user = "postgres"
      end

      if db_name
        Validation.validate_name(db_name)
      else
        db_name = "postgres"
      end

      if postgres_password.nil?
        postgres_password = SecureRandom.urlsafe_base64(15)
      end

      if db_user != "postgres" && db_user_password.nil?
        db_user_password = SecureRandom.urlsafe_base64(15)
      end

      vm_st = Prog::GcpVm::Nexus.assemble_with_sshable(
        "lantern",
        project_id,
        location: location,
        name: name,
        size: target_vm_size,
        storage_size_gib: storage_size_gib,
        boot_image: "ubuntu-2204-jammy-v20240319",
        domain: domain
      )

      st = Prog::Lantern::LanternTimelineNexus.assemble(parent_id: timeline_id)
      timeline = LanternTimeline[st.id]

      if !timeline.parent.nil?
        db_name = timeline.parent.leader.db_name
        db_user = timeline.parent.leader.db_user
        db_user_password = timeline.parent.leader.db_user_password
        postgres_password = timeline.parent.leader.postgres_password
        repl_user = timeline.parent.leader.repl_user
        repl_password = timeline.parent.leader.repl_password
      end

      lantern_server = LanternServer.create(
        project_id: project_id,
        lantern_version: lantern_version,
        extras_version: extras_version,
        location: location,
        minor_version: minor_version,
        org_id: org_id,
        name: name,
        target_vm_size: target_vm_size,
        target_storage_size_gib: storage_size_gib,
        instance_type: instance_type,
        db_name: db_name,
        db_user: db_user,
        db_user_password: db_user_password,
        postgres_password: postgres_password,
        master_host: master_host,
        master_port: master_port,
        vm_id: vm_st.id,
        app_env: app_env,
        debug: enable_debug,
        enable_telemetry: enable_telemetry,
        repl_user: repl_user,
        repl_password: repl_password,
        restore_target: restore_target,
        timeline_id: timeline.id
      ) { _1.id = ubid.to_uuid }

      lantern_server.associate_with_project(project)

      Strand.create(prog: "Lantern::LanternServerNexus", label: "start") { _1.id = lantern_server.id }
    end
  end

  label def start
    nap 5 unless gcp_vm.strand.label == "wait"

    lantern_server.incr_initial_provisioning

    hop_bootstrap_rhizome
  end

  label def update_rhizome
    register_deadline(:wait, 10 * 60)

    decr_update_rhizome
    bud Prog::UpdateRhizome, {"target_folder" => "lantern", "subject_id" => gcp_vm.id, "user" => "lantern"}
    hop_wait_update_rhizome
  end

  label def wait_update_rhizome
    when_update_lantern_extension_set? do
      hop_update_lantern_extension
    end

    when_update_extras_extension_set? do
      hop_update_extras_extension
    end

    when_update_image_set? do
      hop_update_image
    end

    hop_wait
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "lantern", "subject_id" => gcp_vm.id, "user" => "lantern"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    hop_setup_docker_stack if leaf?
    donate
  end

  label def setup_docker_stack
    if !Config.gcp_creds_gcr_b64
      raise "GCP_CREDS_GCR_B64 is required to setup docker stack for Lantern"
    end

    case gcp_vm.sshable.cmd("common/bin/daemonizer --check configure_lantern")
    when "Succeeded"
      gcp_vm.sshable.cmd("common/bin/daemonizer --clean configure_lantern")
      if !gcp_vm.domain.nil?
        lantern_server.incr_add_domain
      end
      hop_wait_db_available
    when "Failed", "NotStarted"
      walg_config = lantern_server.timeline.generate_walg_config
      backup_label = ""
      restore_target = lantern_server.standby? ? "" : lantern_server.restore_target || ""

      # Set backup_label if the database is being initialized from backup
      if !lantern_server.timeline.parent.nil?
        backup_label = if lantern_server.standby? || lantern_server.restore_target.nil?
          "LATEST"
        else
          lantern_server.timeline.parent.latest_backup_label_before_target(lantern_server.restore_target)
        end
      end

      gcp_vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/configure' configure_lantern", stdin: JSON.generate({
        enable_coredumps: true,
        org_id: lantern_server.org_id,
        instance_id: lantern_server.name,
        instance_type: lantern_server.instance_type,
        app_env: lantern_server.app_env,
        enable_debug: lantern_server.debug,
        enable_telemetry: lantern_server.enable_telemetry,
        repl_user: lantern_server.repl_user,
        repl_password: lantern_server.repl_password,
        replication_mode: lantern_server.standby? ? "slave" : "master",
        db_name: lantern_server.db_name,
        db_user: lantern_server.db_user,
        db_user_password: lantern_server.db_user_password,
        postgres_password: lantern_server.postgres_password,
        master_host: lantern_server.master_host,
        master_port: lantern_server.master_port,
        prom_password: Config.prom_password,
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        gcp_creds_coredumps_b64: Config.gcp_creds_coredumps_b64,
        gcp_creds_walg_push_b64: walg_config[:gcp_creds_walg_push_b64],
        walg_gs_push_prefix: walg_config[:walg_gs_push_prefix],
        gcp_creds_walg_pull_b64: walg_config[:gcp_creds_walg_pull_b64],
        walg_gs_pull_prefix: walg_config[:walg_gs_pull_prefix],
        container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}",
        postgresql_recover_from_backup: backup_label,
        postgresql_recovery_target_time: restore_target
      }))
    end

    nap 5
  end

  label def wait_db_available
    nap 10 if !available?

    when_initial_provisioning_set? do
      decr_initial_provisioning
    end

    when_update_memory_limits_set? do
      gcp_vm.sshable.cmd("sudo lantern/bin/update_memory_limits")
      decr_update_memory_limits
    end

    hop_wait
  end

  label def update_lantern_extension
    gcp_vm.sshable.cmd("sudo lantern/bin/update_lantern", stdin: JSON.generate({
      version: lantern_server.lantern_version
    }))
    decr_update_lantern_extension
    hop_wait_db_available
  end

  label def update_extras_extension
    gcp_vm.sshable.cmd("sudo lantern/bin/update_extras", stdin: JSON.generate({
      version: lantern_server.extras_version
    }))
    decr_update_extras_extension
    hop_wait_db_available
  end

  label def update_image
    gcp_vm.sshable.cmd("sudo lantern/bin/update_docker_image", stdin: JSON.generate({
      gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
      container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}"
    }))
    decr_update_image
    hop_wait_db_available
  end

  label def add_domain
    cf_client = Dns::Cloudflare.new
    begin
      cf_client.upsert_dns_record(lantern_server.gcp_vm.domain, lantern_server.gcp_vm.sshable.host)
    rescue => e
      Clog.emit("Error while adding domain") { {error: e} }
      gcp_vm.update(domain: nil)
      decr_add_domain
      hop_wait
    end

    decr_add_domain
    hop_setup_ssl
  end

  def destroy_domain
    cf_client = Dns::Cloudflare.new
    cf_client.delete_dns_record(lantern_server.gcp_vm.domain)
  end

  label def setup_ssl
    gcp_vm.sshable.cmd("sudo lantern/bin/setup_ssl", stdin: JSON.generate({
      dns_token: Config.cf_token,
      dns_zone_id: Config.cf_zone_id,
      dns_email: Config.lantern_dns_email,
      domain: lantern_server.gcp_vm.domain
    }))
    decr_setup_ssl
    hop_wait_db_available
  end

  label def update_user_password
    decr_update_user_password

    if lantern_server.db_user == "postgres"
      hop_wait
    end

    encrypted_password = DB.synchronize do |conn|
      # This uses PostgreSQL's PQencryptPasswordConn function, but it needs a connection, because
      # the encryption is made by PostgreSQL, not by control plane. We use our own control plane
      # database to do the encryption.
      conn.encrypt_password(lantern_server.db_user_password, lantern_server.db_user, "scram-sha-256")
    end
    commands = <<SQL
BEGIN;
SET LOCAL log_statement = 'none';
ALTER ROLE #{lantern_server.db_user} WITH PASSWORD #{DB.literal(encrypted_password)};
COMMIT;
SQL
    lantern_server.run_query(commands)

    hop_wait
  end

  label def wait
    if gcp_vm.strand.label != "wait"
      hop_wait_db_available
    end

    when_update_user_password_set? do
      hop_update_user_password
    end

    # when_checkup_set? do
    #   hop_unavailable if !available?
    # end
    when_destroy_set? do
      hop_destroy
    end

    when_restart_server_set? do
      hop_restart_server
    end

    when_start_server_set? do
      hop_start_server
    end

    when_stop_server_set? do
      hop_stop_server
    end

    when_add_domain_set? do
      hop_add_domain
    end

    when_setup_ssl_set? do
      hop_setup_ssl
    end

    when_update_rhizome_set? do
      hop_update_rhizome
    end

    when_update_storage_size_set? do
      hop_update_storage_size
    end

    when_update_vm_size_set? do
      hop_update_vm_size
    end

    nap 30
  end

  # label def unavailable
  #   register_deadline(:wait, 10 * 60)

  # if postgres_server.primary? && (standby = postgres_server.failover_target)
  #   standby.incr_take_over
  #   postgres_server.incr_destroy
  #   nap 0
  # end

  #   reap
  #   nap 5 unless strand.children.select { _1.prog == "Lantern::LanternServerNexus" && _1.label == "restart" }.empty?
  #
  #   if available?
  #     decr_checkup
  #     hop_wait
  #   end
  #
  #   bud self.class, frame, :restart
  #   nap 5
  # end

  label def destroy
    decr_destroy

    DB.transaction do
      strand.children.each { _1.destroy }

      if !gcp_vm.domain.nil?
        destroy_domain
      end

      lantern_server.projects.map { lantern_server.dissociate_with_project(_1) }

      lantern_server.timeline.incr_destroy
      lantern_server.destroy

      gcp_vm.incr_destroy
    end
    pop "lantern server was deleted"
  end

  label def stop_server
    decr_stop_server
    gcp_vm.incr_stop_vm
    hop_wait
  end

  label def start_server
    decr_start_server
    gcp_vm.incr_start_vm
    hop_wait_db_available
  end

  label def restart_server
    decr_restart_server
    incr_stop_server
    incr_start_server
    hop_wait
  end

  label def update_storage_size
    decr_update_storage_size
    gcp_vm.incr_update_storage
    hop_wait
  end

  label def update_vm_size
    decr_update_vm_size
    gcp_vm.incr_update_size
    incr_update_memory_limits
    hop_wait
  end

  def available?
    gcp_vm.sshable.invalidate_cache_entry

    begin
      lantern_server.run_query("SELECT 1")
      return true
    rescue
    end

    # Do not declare unavailability if Postgres is in crash recovery
    # begin
    #   return true if gcp_vm.sshable.cmd("sudo tail -n 5 /dat/16/data/pg_log/postgresql.log").include?("redo in progress")
    # rescue
    # end

    false
  end
end
