# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Lantern::LanternServerNexus < Prog::Base
  subject_is :lantern_server

  extend Forwardable
  def_delegators :lantern_server, :gcp_vm

  semaphore :initial_provisioning, :update_superuser_password, :checkup
  semaphore :restart, :configure, :take_over, :destroy

  def self.assemble(project_id: nil, lantern_version: "0.2.1", extras_version: "0.1.4", minor_version: "1",
                    org_id: nil, instance_id: nil, instance_type: "writer",
                    db_name: "postgres", db_user: "postgres", db_user_password: nil,
                    location: "us-central1", target_vm_size: nil, storage_size_gib: 50,
                    postgres_password: nil, master_host: nil, master_port: nil)
    DB.transaction do
      unless (parent = Project[project_id])
        fail "No existing parent"
      end
      ubid = LanternServer.generate_ubid
      instance_id ||= LanternServer.ubid_to_name(ubid)

      Validation::validate_name(instance_id)
      Validation::validate_name(db_user)
      Validation::validate_name(db_name)

      if postgres_password == nil
        postgres_password = SecureRandom.urlsafe_base64(15)
      end

      if db_user != "postgres" && db_user_password == nil
        db_user_password = SecureRandom.urlsafe_base64(15)
      end


      vm_st = Prog::GcpVm::Nexus.assemble_with_sshable(
        "lantern",
        project_id,
        location: location,
        name: instance_id,
        size: target_vm_size,
        storage_size_gib: storage_size_gib,
        boot_image: "ubuntu-2204-jammy-v20240319"
      )

      lantern_server = LanternServer.create(
        project_id: project_id,
        lantern_version: lantern_version,
        extras_version: extras_version,
        location: location,
        minor_version: minor_version,
        org_id: org_id,
        instance_id: instance_id,
        instance_type: instance_type,
        db_name: db_name,
        db_user: db_user,
        db_user_password: db_user_password,
        postgres_password: postgres_password,
        master_host: master_host,
        master_port: master_port,
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }

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
    nap 5 unless gcp_vm.strand.label == "wait"

    lantern_server.incr_initial_provisioning
    hop_bootstrap_rhizome
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
    # TODO:: This is not working correctly
    gcp_vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/configure' configure_lantern", stdin: JSON.generate({
      enable_coredumps: true,
      org_id: lantern_server.org_id,
      instance_id: lantern_server.instance_id,
      instance_type: lantern_server.instance_type,
      app_env: Config.rack_env,
      replication_mode: lantern_server.instance_type == "writer" ? "master" : "slave",
      db_name: lantern_server.db_name,
      db_user: lantern_server.db_user,
      db_user_password: lantern_server.db_user_password,
      postgres_password: lantern_server.postgres_password,
      master_host: lantern_server.master_host,
      master_port: lantern_server.master_port,
      enable_telemetry: Config.production?,
      prom_password: Config.prom_password,
      gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
      gcp_creds_coredumps_b64: Config.gcp_creds_coredumps_b64,
      gcp_creds_walg_b64: Config.gcp_creds_walg_b64,
      container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}"
    }))
    hop_wait
  end

  label def configure
    decr_configure

    # case vm.sshable.cmd("common/bin/daemonizer --check configure_postgres")
    # when "Succeeded"
    #   vm.sshable.cmd("common/bin/daemonizer --clean configure_postgres")
    #
    #   when_initial_provisioning_set? do
    #     hop_update_superuser_password if postgres_server.primary?
    #     hop_wait_catch_up if postgres_server.standby?
    #     hop_wait_recovery_completion
    #   end
    #
    #   hop_wait_catch_up if postgres_server.standby? && postgres_server.synchronization_status != "ready"
    #   hop_wait
    # when "Failed", "NotStarted"
    #   configure_hash = postgres_server.configure_hash
    #   vm.sshable.cmd("common/bin/daemonizer 'sudo postgres/bin/configure' configure_postgres", stdin: JSON.generate(configure_hash))
    # end

    nap 5
  end

  label def update_superuser_password
    decr_update_superuser_password

#     encrypted_password = DB.synchronize do |conn|
#       # This uses PostgreSQL's PQencryptPasswordConn function, but it needs a connection, because
#       # the encryption is made by PostgreSQL, not by control plane. We use our own control plane
#       # database to do the encryption.
#       conn.encrypt_password(postgres_server.resource.superuser_password, "postgres", "scram-sha-256")
#     end
#     commands = <<SQL
# BEGIN;
# SET LOCAL log_statement = 'none';
# ALTER ROLE postgres WITH PASSWORD #{DB.literal(encrypted_password)};
# COMMIT;
# SQL
#     postgres_server.run_query(commands)
#
#     when_initial_provisioning_set? do
#       hop_wait if retval&.dig("msg") == "postgres server is restarted"
#       push self.class, frame, "restart"
#     end

    hop_wait
  end

  label def wait_catch_up
    # query = "SELECT pg_current_wal_lsn() - replay_lsn FROM pg_stat_replication WHERE application_name = '#{postgres_server.ubid}'"
    # lag = postgres_server.resource.representative_server.run_query(query).chomp
    #
    # nap 30 if lag.empty? || lag.to_i > 80 * 1024 * 1024 # 80 MB or ~5 WAL files
    #
    # postgres_server.update(synchronization_status: "ready")
    # postgres_server.resource.representative_server.incr_configure
    # hop_wait_synchronization if postgres_server.resource.ha_type == PostgresResource::HaType::SYNC
    hop_wait
  end

  label def wait_synchronization
    # query = "SELECT sync_state FROM pg_stat_replication WHERE application_name = '#{postgres_server.ubid}'"
    # sync_state = postgres_server.resource.representative_server.run_query(query).chomp
    # hop_wait if ["quorum", "sync"].include?(sync_state)

    nap 30
  end

  label def wait_recovery_completion
    # is_in_recovery = postgres_server.run_query("SELECT pg_is_in_recovery()").chomp == "t"
    #
    # if is_in_recovery
    #   is_wal_replay_paused = postgres_server.run_query("SELECT pg_get_wal_replay_pause_state()").chomp == "paused"
    #   if is_wal_replay_paused
    #     postgres_server.run_query("SELECT pg_wal_replay_resume()")
    #     is_in_recovery = false
    #   end
    # end
    #
    # if !is_in_recovery
    #   timeline_id = Prog::Postgres::PostgresTimelineNexus.assemble(parent_id: postgres_server.timeline.id).id
    #   postgres_server.timeline_id = timeline_id
    #   postgres_server.timeline_access = "push"
    #   postgres_server.save_changes
    #
    #   refresh_walg_credentials
    #
    #   hop_configure
    # end

    nap 5
  end

  label def wait
    decr_initial_provisioning

    when_update_superuser_password_set? do
      hop_update_superuser_password
    end

    when_checkup_set? do
      hop_unavailable if !available?
    end


    when_restart_set? do
      push self.class, frame, "restart"
    end

    nap 30
  end

  label def unavailable
    register_deadline(:wait, 10 * 60)

    # if postgres_server.primary? && (standby = postgres_server.failover_target)
    #   standby.incr_take_over
    #   postgres_server.incr_destroy
    #   nap 0
    # end

    reap
    nap 5 unless strand.children.select { _1.prog == "Lantern::LanternServerNexus" && _1.label == "restart" }.empty?

    if available?
      decr_checkup
      hop_wait
    end

    bud self.class, frame, :restart
    nap 5
  end

  label def wait_primary_destroy
    decr_take_over
    # hop_take_over if postgres_server.resource.representative_server.nil?
    nap 5
  end

  label def destroy
    decr_destroy

    strand.children.each { _1.destroy }
    gcp_vm.incr_destroy
    lantern_server.destroy

    pop "postgres server is deleted"
  end

  label def restart
    decr_restart
    gcp_vm.sshable.cmd("sudo postgres/bin/restart")
    pop "postgres server is restarted"
  end

  def available?
    gcp_vm.sshable.invalidate_cache_entry

    begin
      lantern_server.run_query("SELECT 1")
      return true
    rescue
    end

    # Do not declare unavailability if Postgres is in crash recovery
    begin
      return true if gcp_vm.sshable.cmd("sudo tail -n 5 /dat/16/data/pg_log/postgresql.log").include?("redo in progress")
    rescue
    end

    false
  end
end
