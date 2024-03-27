# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Lantern::LanternServerNexus < Prog::Base
  subject_is :lantern_server

  extend Forwardable
  def_delegators :lantern_server, :gcp_vm

  semaphore :initial_provisioning, :update_superuser_password, :update_lantern_extension, :update_extras_extension, :update_image, :setup_ssl, :add_domain, :update_rhizome, :checkup
  semaphore :restart, :configure, :take_over, :destroy

  def self.assemble(project_id: nil, lantern_version: "0.2.1", extras_version: "0.1.4", minor_version: "1",
    org_id: nil, name: nil, instance_type: "writer",
    db_name: "postgres", db_user: "postgres", db_user_password: nil,
    location: "us-central1", target_vm_size: nil, storage_size_gib: 50,
    postgres_password: nil, master_host: nil, master_port: nil, domain: nil)
    DB.transaction do
      unless (project = Project[project_id])
        fail "No existing parent"
      end
      ubid = LanternServer.generate_ubid
      name ||= LanternServer.ubid_to_name(ubid)

      Validation::validate_name(name)
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
        name: name,
        size: target_vm_size,
        storage_size_gib: storage_size_gib,
        boot_image: "ubuntu-2204-jammy-v20240319",
        domain: domain
      )

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
        vm_id: vm_st.id
      ) { _1.id = ubid.to_uuid }
      lantern_server.associate_with_project(project)

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

    if gcp_vm.domain
      lantern_server.incr_add_domain
    end

    hop_bootstrap_rhizome
  end

  label def update_rhizome
    register_deadline(:wait, 10 * 60)

    decr_update_rhizome
    bud Prog::UpdateRhizome, {"target_folder" => "lantern", "subject_id" => gcp_vm.id, "user" => "lantern"}
    hop_wait_update_rhizome
  end

  label def wait_update_rhizome
    reap
    hop_wait if leaf?
    donate
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

    gcp_vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/configure' configure_lantern", stdin: JSON.generate({
      enable_coredumps: true,
      org_id: lantern_server.org_id,
      instance_id: lantern_server.name,
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
      dns_token: Config.cf_token,
      dns_email: Config.cf_email,
      domain: lantern_server.gcp_vm.domain,
      container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}"
    }))

    hop_wait_db_available
  end

  label def wait_db_available
    if available?
      hop_wait
    end

    nap 10
  end

  label def configure
    decr_configure
    nap 5
  end

  label def update_lantern_extension
    gcp_vm.sshable.cmd("sudo lantern/bin/update_lantern", stdin: JSON.generate({
      version: lantern_server.lantern_version
    }))
    decr_update_lantern_extension
    hop_wait
  end

  label def update_extras_extension
    gcp_vm.sshable.cmd("sudo lantern/bin/update_extras", stdin: JSON.generate({
      version: lantern_server.extras_version
    }))
    decr_update_extras_extension
    hop_wait
  end

  label def update_image
    gcp_vm.sshable.cmd("sudo lantern/bin/update_docker_image", stdin: JSON.generate({
      gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
      container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}"
    }))
    decr_update_image
    hop_wait
  end

  label def add_domain
    cf_client = Dns::Cloudflare::new
    begin
      puts "upsert_dns_record"
      cf_client.upsert_dns_record(lantern_server.gcp_vm.domain, lantern_server.gcp_vm.sshable.host)
      puts "upserted_dns_record"
    rescue => e
      Clog.emit("Error while adding domain") {{ error: e }}
      gcp_vm.update(domain: nil)
      decr_add_domain
      hop_wait
    end

    decr_add_domain
    hop_setup_ssl
  end

  def destroy_domain
    cf_client = Dns::Cloudflare::new
    cf_client.delete_dns_record(lantern_server.gcp_vm.domain)
  end

  # TODO::Test
  label def setup_ssl
    if lantern_server.gcp_vm.domain && Config.lantern_dns_token_tls
      gcp_vm.sshable.cmd("sudo lantern/bin/setup_ssl", stdin: JSON.generate({
        dns_token: Config.cf_token,
        dns_zone_id: Config.cf_zone_id,
        dns_email: Config.lantern_dns_email_tls,
        domain: lantern_server.gcp_vm.domain,
      }))
    end
    decr_setup_ssl
    hop_wait
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

    when_update_lantern_extension_set? do
      hop_update_lantern_extension
    end

    when_update_extras_extension_set? do
      hop_update_extras_extension
    end

    when_update_image_set? do
      hop_update_image
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

    if gcp_vm.domain != nil
      destroy_domain(gcp_vm.domain)
    end

    gcp_vm.incr_destroy
    lantern_server.destroy
    pop "postgres server is deleted"
  end

  label def restart
    decr_restart
    gcp_vm.sshable.cmd("sudo postgres/bin/restart")
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
