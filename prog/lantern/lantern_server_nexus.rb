# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Lantern::LanternServerNexus < Prog::Base
  subject_is :lantern_server

  extend Forwardable
  def_delegators :lantern_server, :vm

  semaphore :initial_provisioning, :update_user_password, :update_lantern_extension, :update_extras_extension, :update_image, :add_domain, :update_rhizome, :checkup
  semaphore :start_server, :stop_server, :restart_server, :take_over, :destroy, :update_storage_size, :update_vm_size, :update_memory_limits, :init_sql, :restart

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
        boot_image: LanternServer.get_vm_image(lantern_version, extras_version, minor_version),
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
    nap 5 unless vm.strand.label == "wait" && lantern_server.resource.strand.label != "start"

    lantern_server.incr_initial_provisioning

    hop_bootstrap_rhizome
  end

  label def update_rhizome
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
    register_deadline(:setup_docker_stack, 10 * 60)

    bud Prog::BootstrapRhizome, {"target_folder" => "lantern", "subject_id" => vm.id, "user" => "lantern"}
    hop_wait_bootstrap_rhizome
  end

  label def wait_bootstrap_rhizome
    reap
    if leaf?
      register_deadline(:wait_db_available, 10 * 60)
      hop_setup_docker_stack
    end
    donate
  end

  label def setup_docker_stack
    if !Config.gcp_creds_gcr_b64
      raise "GCP_CREDS_GCR_B64 is required to setup docker stack for Lantern"
    end

    # wait for service account to be created
    nap 10 if lantern_server.timeline.strand.label == "start"

    case vm.sshable.cmd("common/bin/daemonizer --check configure_lantern")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean configure_lantern")
      if !lantern_server.domain.nil?
        lantern_server.incr_add_domain
      end

      # set higher deadline for secondary as it needs time
      # to download backcup and replay wal
      if lantern_server.primary?
        register_deadline(:wait, 40 * 60)
      else
        register_deadline(:wait, 120 * 60)
      end

      hop_wait_db_available
    when "Failed", "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/configure' configure_lantern", stdin: lantern_server.configure_hash)
    end

    nap 5
  end

  label def init_sql
    case vm.sshable.cmd("common/bin/daemonizer --check init_sql")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean init_sql")
      bud self.class, frame, :prewarm_indexes
      hop_wait_db_available
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/init_sql' init_sql")
    when "Failed"
      Prog::PageNexus.assemble("Lantern init sql failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternInitSQLFailed", lantern_server.container_image)
      vm.sshable.cmd("common/bin/daemonizer --clean init_sql")
      hop_wait
    end
    nap 5
  end

  label def wait_catch_up
    query = "SELECT pg_current_wal_lsn() - replay_lsn FROM pg_stat_replication WHERE application_name = 'walreceiver'"
    lag = lantern_server.resource.representative_server.run_query(query).chomp

    nap 30 if lag.empty? || lag.to_i > 80 * 1024 * 1024 # 80 MB or ~5 WAL files

    lantern_server.update(synchronization_status: "ready")
    hop_wait_synchronization if lantern_server.resource.ha_type == LanternResource::HaType::SYNC
    hop_wait
  end

  label def wait_synchronization
    query = "SELECT sync_state FROM pg_stat_replication WHERE application_name = 'walreceiver'"
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
      lantern_server.resource.allow_timeline_access_to_bucket

      if !lantern_server.resource.version_upgrade
        lantern_version = lantern_server.run_query("SELECT extversion FROM pg_extension WHERE extname='lantern'")
        extras_version = lantern_server.run_query("SELECT extversion FROM pg_extension WHERE extname='lantern_extras'")

        if lantern_version != lantern_server.lantern_version
          incr_update_lantern_extension
          lantern_server.update(lantern_version: lantern_version)
        end

        if extras_version != lantern_server.extras_version
          incr_update_extras_extension
          lantern_server.update(extras_version: extras_version)
        end
      end

      hop_wait_timeline_available
    end

    nap 5
  end

  label def wait_timeline_available
    nap 10 if lantern_server.timeline.strand.label == "start"
    lantern_server.update_walg_creds
    decr_initial_provisioning
    hop_wait_db_available
  end

  label def wait_db_available
    nap 10 if !available?

    when_initial_provisioning_set? do
      decr_initial_provisioning

      if lantern_server.primary?
        hop_init_sql
      end
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
      register_deadline(:wait, 40 * 60)
      hop_init_sql
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/update_lantern' update_lantern", stdin: JSON.generate({version: lantern_server.lantern_version}))
    when "Failed"
      logs = JSON.parse(vm.sshable.cmd("common/bin/daemonizer --logs update_lantern"))
      Clog.emit("Lantern update failed") { {logs: logs, name: lantern_server.resource.name, lantern_server: lantern_server.id} }
      Prog::PageNexus.assemble_with_logs("Lantern v#{lantern_server.lantern_version} update failed!", [lantern_server.resource.ubid, lantern_server.ubid], logs, "critical", "LanternUpdateFailed", lantern_server.ubid)
      vm.sshable.cmd("common/bin/daemonizer --clean update_lantern")
      decr_update_lantern_extension
      hop_wait
    end
    nap 10
  end

  label def update_extras_extension
    case vm.sshable.cmd("common/bin/daemonizer --check update_extras")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean update_extras")
      decr_update_extras_extension
      register_deadline(:wait, 40 * 60)
      hop_init_sql
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/update_extras' update_extras", stdin: JSON.generate({version: lantern_server.extras_version}))
    when "Failed"
      logs = JSON.parse(vm.sshable.cmd("common/bin/daemonizer --logs update_extras"))
      Clog.emit("Lantern extras update failed") { {logs: logs, name: lantern_server.resource.name, lantern_server: lantern_server.id} }
      Prog::PageNexus.assemble_with_logs("Lantern Extras v#{lantern_server.extras_version} update failed!", [lantern_server.resource.ubid, lantern_server.ubid], logs, "critical", "LanternExtrasUpdateFailed", lantern_server.ubid)
      vm.sshable.cmd("common/bin/daemonizer --clean update_extras")
      decr_update_extras_extension
      hop_wait
    end
    nap 10
  end

  label def update_image
    case vm.sshable.cmd("common/bin/daemonizer --check update_docker_image")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean update_docker_image")
      decr_update_image
      # Update lantern to build extension with march_native on the machine
      hop_update_lantern_extension
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/update_docker_image' update_docker_image", stdin: JSON.generate({
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        container_image: lantern_server.container_image
      }))
    when "Failed"
      logs = JSON.parse(vm.sshable.cmd("common/bin/daemonizer --logs update_docker_image"))
      Clog.emit("Lantern image update failed") { {logs: logs, name: lantern_server.resource.name, lantern_server: lantern_server.id} }
      Prog::PageNexus.assemble_with_logs("Lantern Image #{lantern_server.container_image} update failed!", [lantern_server.resource.ubid, lantern_server.ubid], logs, "critical", "LanternImageUpdateFailed", lantern_server.ubid)
      vm.sshable.cmd("common/bin/daemonizer --clean update_docker_image")
      decr_update_image
      hop_wait
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
    register_deadline(:wait, 5 * 60)
    hop_setup_ssl
  end

  def destroy_domain
    cf_client = Dns::Cloudflare.new
    cf_client.delete_dns_record(lantern_server.domain)
  end

  label def setup_ssl
    case vm.sshable.cmd("common/bin/daemonizer --check setup_ssl")
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean setup_ssl")
      decr_update_image
      # Update lantern to build extension with march_native on the machine
      hop_wait_db_available
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/setup_ssl' setup_ssl", stdin: JSON.generate({
        dns_token: Config.cf_token,
        dns_zone_id: Config.cf_zone_id,
        dns_email: Config.lantern_dns_email,
        domain: lantern_server.domain
      }))
    when "Failed"
      logs = JSON.parse(vm.sshable.cmd("common/bin/daemonizer --logs setup_ssl"))
      Clog.emit("Lantern SSL Setup Failed for #{lantern_server.resource.name}") { {logs: logs, name: lantern_server.resource.name, lantern_server: lantern_server.id} }
      Prog::PageNexus.assemble_with_logs("Lantern SSL Setup Failed for #{lantern_server.resource.name}", [lantern_server.resource.ubid, lantern_server.ubid], logs, "error", "LanternSSLSetupFailed", lantern_server.ubid)
      vm.sshable.cmd("common/bin/daemonizer --clean setup_ssl")
      hop_wait
    end
    nap 10
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
    reap

    when_checkup_set? do
      decr_checkup
      if !available?
        register_deadline(:wait, 5 * 60)
        hop_unavailable
      end
    end

    when_update_user_password_set? do
      hop_update_user_password
    end

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

    # We will always update rhizome before updating extensions
    # In case something is changed in rhizome scripts
    when_update_lantern_extension_set? do
      hop_update_rhizome
    end

    when_update_extras_extension_set? do
      hop_update_rhizome
    end

    when_update_image_set? do
      hop_update_rhizome
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

    when_take_over_set? do
      hop_take_over
    end

    nap 30
  end

  label def promote_server
    current_master = lantern_server.resource.representative_server
    current_master_domain = current_master.domain
    new_master_domain = lantern_server.domain

    lantern_server.update(domain: current_master_domain)
    current_master.update(domain: new_master_domain)

    lantern_server.run_query("SELECT pg_promote(true, 120);")
    lantern_server.resource.set_to_readonly(status: "off")
    current_master.change_replication_mode("slave")
    lantern_server.change_replication_mode("master", lazy: false)

    hop_wait
  end

  label def wait_swap_ip
    # wait until ip change will propogate
    begin
      is_in_recovery = lantern_server.run_query("SELECT pg_is_in_recovery()").chomp == "t"
      nap 5 if !is_in_recovery
    rescue
      nap 5
    end

    hop_promote_server
  end

  label def take_over
    decr_take_over
    if !lantern_server.standby?
      hop_wait
    end

    lantern_server.resource.set_to_readonly(status: "on")
    lantern_server.vm.swap_ip(lantern_server.resource.representative_server.vm)

    register_deadline(:promote_server, 5 * 60)
    hop_wait_swap_ip
  end

  label def unavailable
    # TODO
    # if postgres_server.primary? && (standby = postgres_server.failover_target)
    #   standby.incr_take_over
    #   postgres_server.incr_destroy
    #   nap 0
    # end

    reap
    nap 5 unless strand.children.select { _1.prog == "Lantern::LanternServerNexus" && _1.label == "restart" }.empty?

    page = Page.from_tag_parts("DBUnavailable", lantern_server.id)
    if available?
      decr_checkup
      page&.incr_resolve
      hop_wait
    end

    if page.nil?

      logs = {"stdout" => "", "stderr" => ""}
      begin
        logs["stdout"] = vm.sshable.cmd("sudo lantern/bin/logs --tail 10")
      rescue
      end

      Clog.emit("Database unavailable") { {logs: logs, name: lantern_server.resource.name, lantern_server: lantern_server.id} }
      Prog::PageNexus.assemble_with_logs("DB #{lantern_server.resource.name} is unavailable!", [lantern_server.ubid], logs, "critical", "DBUnavailable", lantern_server.id)
    else
      nap 5
    end

    bud self.class, frame, :restart
    nap 5
  end

  label def destroy
    decr_destroy

    DB.transaction do
      strand.children.each { _1.destroy }

      if !lantern_server.domain.nil?
        destroy_domain
      end

      if lantern_server.primary?
        lantern_server.timeline.incr_destroy
      end
      lantern_server.destroy

      vm.incr_destroy
    end
    pop "lantern server was deleted"
  end

  label def restart
    decr_restart
    vm.sshable.cmd("sudo lantern/bin/restart")
    pop "lantern server is restarted"
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

  label def prewarm_indexes
    case vm.sshable.cmd("common/bin/daemonizer --check prewarm_indexes")
    when "NotStarted"
      vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/exec_all' prewarm_indexes", stdin: lantern_server.prewarm_indexes_query)
    when "Succeeded"
      vm.sshable.cmd("common/bin/daemonizer --clean prewarm_indexes")
      Page.from_tag_parts("LanternPrewarmFailed", lantern_server.id)&.incr_resolve
      pop "lantern index prewarm success"
    when "Failed"
      logs = JSON.parse(vm.sshable.cmd("common/bin/daemonizer --logs prewarm_indexes"))
      Clog.emit("Lantern index prewarm failed") { {logs: logs, name: lantern_server.resource.name, lantern_server: lantern_server.id} }
      Prog::PageNexus.assemble_with_logs("Lantern prewarm indexes failed", [lantern_server.resource.ubid, lantern_server.ubid], logs, "warning", "LanternPrewarmFailed", lantern_server.ubid)
      vm.sshable.cmd("common/bin/daemonizer --clean prewarm_indexes")
      pop "lantern index prewarm failed"
    end

    nap 30
  end
end
