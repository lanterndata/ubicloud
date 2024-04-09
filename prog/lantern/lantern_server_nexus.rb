# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Lantern::LanternServerNexus < Prog::Base
  subject_is :lantern_server

  extend Forwardable
  def_delegators :lantern_server, :vm

  semaphore :initial_provisioning, :update_user_password, :update_lantern_extension, :update_extras_extension, :update_image, :add_domain, :update_rhizome, :checkup
  semaphore :start_server, :stop_server, :restart_server, :take_over, :destroy, :update_storage_size, :update_vm_size, :update_memory_limits, :init_sql

  def self.assemble(
    resource_id: nil, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "1", domain: nil,
    timeline_access: "push", representative_at: nil, target_vm_size: nil, target_storage_size_gib: 50, timeline_id: nil
  )

    DB.transaction do
      unless (resource = LanternResource[resource_id])
        fail "No existing parent"
      end

      if !domain.nil?
        Validation.validate_domain(domain)
      end

      vm_st = Prog::GcpVm::Nexus.assemble_with_sshable(
        "lantern",
        resource.project_id,
        location: resource.location,
        size: target_vm_size,
        storage_size_gib: target_storage_size_gib,
        boot_image: "ubuntu-2204-jammy-v20240319",
        labels: {"parent" => resource.name}
      )

      lantern_server = LanternServer.create_with_id(
        resource_id: resource_id,
        lantern_version: lantern_version,
        extras_version: extras_version,
        minor_version: minor_version,
        target_vm_size: target_vm_size,
        target_storage_size_gib: target_storage_size_gib,
        vm_id: vm_st.id,
        timeline_access: timeline_access,
        timeline_id: timeline_id,
        representative_at: representative_at,
        synchronization_status: representative_at ? "ready" : "catching_up",
        domain: domain
      )

      Strand.create(prog: "Lantern::LanternServerNexus", label: "start") { _1.id = lantern_server.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      elsif strand.stack.count > 1
        pop "operation is cancelled due to the destruction of the postgres server"
      end
    end
  end

  label def start
    nap 5 unless vm.strand.label == "wait"

    lantern_server.incr_initial_provisioning

    hop_bootstrap_rhizome
  end

  label def update_rhizome
    register_deadline(:wait, 10 * 60)

    decr_update_rhizome
    bud Prog::UpdateRhizome, {"target_folder" => "lantern", "subject_id" => vm.id, "user" => "lantern"}
    hop_wait_update_rhizome
  end

  label def wait_update_rhizome
    reap
    if leaf?
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
    donate
  end

  label def bootstrap_rhizome
    register_deadline(:wait, 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "lantern", "subject_id" => vm.id, "user" => "lantern"}
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

    register_deadline(:wait, 10 * 60)

    case vm.sshable.cmd("common/bin/daemonizer --check configure_lantern")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean configure_lantern")
      if !lantern_server.domain.nil?
        lantern_server.incr_add_domain
      end
      hop_wait_db_available
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/configure' configure_lantern", stdin: lantern_server.configure_hash)
    end

    nap 5
  end

  label def init_sql
    register_deadline(:wait, 5 * 60)

    case vm.sshable.cmd("common/bin/daemonizer --check init_sql")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean init_sql")
      hop_wait_db_available
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/init_sql' init_sql")
    end
    nap 5
  end

  label def wait_catch_up
    query = "SELECT pg_current_wal_lsn() - replay_lsn FROM pg_stat_replication WHERE application_name = '#{lantern_server.ubid}'"
    lag = lantern_server.resource.representative_server.run_query(query).chomp

    nap 30 if lag.empty? || lag.to_i > 80 * 1024 * 1024 # 80 MB or ~5 WAL files

    lantern_server.update(synchronization_status: "ready")
    hop_wait_synchronization if lantern_server.resource.ha_type == LanternResource::HaType::SYNC
    hop_wait
  end

  label def wait_synchronization
    query = "SELECT sync_state FROM pg_stat_replication WHERE application_name = '#{lantern_server.ubid}'"
    sync_state = lantern_server.resource.representative_server.run_query(query).chomp
    hop_wait if ["quorum", "sync"].include?(sync_state)

    nap 30
  end

  label def wait_recovery_completion
    is_in_recovery = lantern_server.run_query("SELECT pg_is_in_recovery()").chomp == "t"

    if is_in_recovery
      is_wal_replay_paused = lantern_server.run_query("SELECT pg_get_wal_replay_pause_state()").chomp == "paused"
      if is_wal_replay_paused
        lantern_server.run_query("SELECT pg_wal_replay_resume()")
        is_in_recovery = false
      end
    end

    if !is_in_recovery
      timeline_id = Prog::Lantern::LanternTimelineNexus.assemble(parent_id: lantern_server.timeline.id).id
      lantern_server.timeline_id = timeline_id
      lantern_server.timeline_access = "push"
      lantern_server.save_changes

      lantern_server.update_walg_creds

      hop_wait
    end

    nap 5
  end

  label def wait_db_available
    nap 10 if !available?

    when_initial_provisioning_set? do
      decr_initial_provisioning

      hop_init_sql if lantern_server.primary?
      hop_wait_catch_up if lantern_server.standby?
      hop_wait_recovery_completion
    end

    when_update_memory_limits_set? do
      vm.sshable.cmd("sudo lantern/bin/update_memory_limits")
      decr_update_memory_limits
    end

    hop_wait
  end

  label def update_lantern_extension
    case vm.sshable.cmd("common/bin/daemonizer --check update_lantern")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean update_lantern")
      decr_update_lantern_extension
      hop_wait_db_available
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/update_lantern' update_lantern", stdin: JSON.generate({version: lantern_server.lantern_version}))
    when "Failed"
      Prog::PageNexus.assemble("Lantern v#{lantern_server.lantern_version} update failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternUpdateFailed", lantern_server.lantern_version)
      decr_update_lantern_extension
      hop_wait_db_available
    end
    nap 10
  end

  label def update_extras_extension
    case vm.sshable.cmd("common/bin/daemonizer --check update_extras")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean update_extras")
      decr_update_extras_extension
      hop_wait_db_available
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/update_extras' update_lantern", stdin: JSON.generate({version: lantern_server.extras_version}))
    when "Failed"
      Prog::PageNexus.assemble("Lantern Extras v#{lantern_server.extras_version} update failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternUpdateFailed", lantern_server.extras_version)
      decr_update_extras_extension
      hop_wait_db_available
    end
    nap 10
  end

  label def update_image
    case vm.sshable.cmd("common/bin/daemonizer --check update_image")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean update_image")
      decr_update_image
      hop_wait_db_available
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/update_image' update_image", stdin: JSON.generate({
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        container_image: lantern_server.container_image
      }))
    when "Failed"
      Prog::PageNexus.assemble("Lantern Image #{lantern_server.container_image} update failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternUpdateFailed", lantern_server.container_image)
      decr_update_image
      hop_wait_db_available
    end
    nap 10
  end

  label def add_domain
    cf_client = Dns::Cloudflare.new
    begin
      cf_client.upsert_dns_record(lantern_server.domain, lantern_server.vm.sshable.host)
    rescue => e
      Clog.emit("Error while adding domain") { {error: e} }
      lantern_server.update(domain: nil)
      decr_add_domain
      hop_wait
    end

    decr_add_domain
    hop_setup_ssl
  end

  def destroy_domain
    cf_client = Dns::Cloudflare.new
    cf_client.delete_dns_record(lantern_server.domain)
  end

  label def setup_ssl
    vm.sshable.cmd("sudo lantern/bin/setup_ssl", stdin: JSON.generate({
      dns_token: Config.cf_token,
      dns_zone_id: Config.cf_zone_id,
      dns_email: Config.lantern_dns_email,
      domain: lantern_server.domain
    }))
    hop_wait_db_available
  end

  label def update_user_password
    decr_update_user_password

    if lantern_server.resource.db_user == "postgres"
      hop_wait
    end

    encrypted_password = DB.synchronize do |conn|
      # This uses PostgreSQL's PQencryptPasswordConn function, but it needs a connection, because
      # the encryption is made by PostgreSQL, not by control plane. We use our own control plane
      # database to do the encryption.
      conn.encrypt_password(lantern_server.resource.db_user_password, lantern_server.resource.db_user, "scram-sha-256")
    end
    commands = <<SQL
BEGIN;
SET LOCAL log_statement = 'none';
ALTER ROLE #{lantern_server.resource.db_user} WITH PASSWORD #{DB.literal(encrypted_password)};
COMMIT;
SQL
    lantern_server.run_query(commands)

    hop_wait
  end

  label def wait
    if vm.strand.label != "wait"
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

      if !lantern_server.domain.nil?
        destroy_domain
      end

      lantern_server.timeline.incr_destroy
      lantern_server.destroy

      vm.incr_destroy
    end
    pop "lantern server was deleted"
  end

  label def stop_server
    decr_stop_server
    vm.incr_stop_vm
    hop_wait
  end

  label def start_server
    decr_start_server
    vm.incr_start_vm
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
    vm.incr_update_storage
    hop_wait
  end

  label def update_vm_size
    decr_update_vm_size
    vm.incr_update_size
    incr_update_memory_limits
    hop_wait
  end

  def available?
    vm.sshable.invalidate_cache_entry

    begin
      lantern_server.run_query("SELECT 1")
      return true
    rescue
    end

    # Do not declare unavailability if Postgres is in crash recovery
    begin
      return true if vm.sshable.cmd("sudo lantern/bin/logs --tail 5").include?("redo in progress")
    rescue
    end

    false
  end
end
