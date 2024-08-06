# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe LanternServer do
  subject(:lantern_server) {
    described_class.new { _1.id = "c068cac7-ed45-82db-bf38-a003582b36ee" }
  }

  before do
    allow(described_class).to receive(:get_vm_image).and_return(Config.gcp_default_image)
    allow(lantern_server).to receive(:gcp_vm).and_return(vm)
  end

  let(:vm) {
    instance_double(
      GcpVm,
      sshable: instance_double(Sshable, host: "127.0.0.1"),
      mem_gib: 8
    )
  }

  describe "#instance_type" do
    it "returns reader" do
      expect(lantern_server).to receive(:standby?).and_return(true)
      expect(lantern_server.instance_type).to eq("reader")
    end

    it "returns writer" do
      expect(lantern_server).to receive(:standby?).and_return(false)
      expect(lantern_server.instance_type).to eq("writer")
    end
  end

  describe "#display_state" do
    it "shows domain setup" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "setup domain")).at_least(:once)
      expect(lantern_server.display_state).to eq("domain setup")
    end

    it "shows ssl setup" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "setup_ssl")).at_least(:once)
      expect(lantern_server.display_state).to eq("ssl setup")
    end

    it "shows updating" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "update_extension")).at_least(:once)
      expect(lantern_server.display_state).to eq("updating")
    end

    it "shows updating from vm status" do
      expect(lantern_server.vm).to receive(:display_state).and_return("updating").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(lantern_server.display_state).to eq("updating")
    end

    it "shows updating if init_sql" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "init_sql")).at_least(:once)
      expect(lantern_server.display_state).to eq("updating")
    end

    it "shows running" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(lantern_server.display_state).to eq("running")
    end

    it "shows deleting" do
      expect(lantern_server).to receive(:destroy_set?).and_return(false).at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "destroy")).at_least(:once)
      expect(lantern_server.display_state).to eq("deleting")
    end

    it "shows deleting if destroy set" do
      expect(lantern_server).to receive(:destroy_set?).and_return(true).at_least(:once)
      expect(lantern_server.display_state).to eq("deleting")
    end

    it "shows unavailable" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait_db_available")).at_least(:once)
      expect(lantern_server.display_state).to eq("unavailable")
    end

    it "shows creating" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "unknown")).at_least(:once)
      expect(lantern_server.display_state).to eq("creating")
    end

    it "shows starting" do
      expect(lantern_server.vm).to receive(:display_state).and_return("starting").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "unknown")).at_least(:once)
      expect(lantern_server.display_state).to eq("starting")
    end

    it "shows stopping" do
      expect(lantern_server.vm).to receive(:display_state).and_return("stopping").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "unknown")).at_least(:once)
      expect(lantern_server.display_state).to eq("stopping")
    end

    it "shows stopped" do
      expect(lantern_server.vm).to receive(:display_state).and_return("stopped").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "unknown")).at_least(:once)
      expect(lantern_server.display_state).to eq("stopped")
    end

    it "shows stopped (container)" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "container_stopped")).at_least(:once)
      expect(lantern_server.display_state).to eq("stopped")
    end

    it "shows failed" do
      expect(lantern_server.vm).to receive(:display_state).and_return("failed").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "unknown")).at_least(:once)
      expect(lantern_server.display_state).to eq("failed")
    end

    it "shows failover when label is take_over" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "take_over")).at_least(:once)
      expect(lantern_server.display_state).to eq("failover")
    end

    it "shows failover when label is wait_swap_ip" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait_swap_ip")).at_least(:once)
      expect(lantern_server.display_state).to eq("failover")
    end

    it "shows failover when label is promote_server" do
      expect(lantern_server.vm).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "promote_server")).at_least(:once)
      expect(lantern_server.display_state).to eq("failover")
    end
  end

  it "returns name from ubid" do
    expect(described_class.ubid_to_name(lantern_server.id)).to eq("c068cac7")
  end

  it "runs query on vm" do
    expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -q -U postgres -t --csv postgres", stdin: "SELECT 1").and_return("1\n")
    expect(lantern_server.run_query("SELECT 1")).to eq("1")
  end

  it "runs query on vm with different user and db" do
    expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -q -U lantern -t --csv db2", stdin: "SELECT 1").and_return("1\n")
    expect(lantern_server.run_query("SELECT 1", db: "db2", user: "lantern")).to eq("1")
  end

  it "runs query on vm for all databases" do
    expect(lantern_server).to receive(:list_all_databases).and_return(["postgres", "db2"])
    expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -q -U postgres -t --csv postgres", stdin: "SELECT 1").and_return("1\n")
    expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec -T postgresql psql -q -U postgres -t --csv db2", stdin: "SELECT 1").and_return("2\n")
    expect(lantern_server.run_query_all("SELECT 1")).to eq(
      [
        ["postgres", "1"],
        ["db2", "2"]
      ]
    )
  end

  describe "#standby?" do
    it "false if timeline is push" do
      expect(lantern_server).to receive(:timeline_access).and_return("push")
      expect(lantern_server.standby?).to be(false)
    end

    it "false if timeline is fetch and pitr" do
      expect(lantern_server).to receive(:doing_pitr?).and_return(true)
      expect(lantern_server).to receive(:timeline_access).and_return("fetch")
      expect(lantern_server.standby?).to be(false)
    end

    it "true if timeline is fetch and no pitr" do
      expect(lantern_server).to receive(:doing_pitr?).and_return(false)
      expect(lantern_server).to receive(:timeline_access).and_return("fetch")
      expect(lantern_server.standby?).to be(true)
    end
  end

  describe "#primary?" do
    it "true if timeline is push" do
      expect(lantern_server).to receive(:timeline_access).and_return("push")
      expect(lantern_server.primary?).to be(true)
    end

    it "false if timeline is fetch" do
      expect(lantern_server).to receive(:timeline_access).and_return("fetch")
      expect(lantern_server.primary?).to be(false)
    end
  end

  describe "#doing_pitr?" do
    it "returns false if representative is primary" do
      expect(lantern_server).to receive(:resource).and_return(instance_double(LanternResource, representative_server: instance_double(described_class, primary?: true)))
      expect(lantern_server.doing_pitr?).to be(false)
    end

    it "returns true if representative is not primary" do
      expect(lantern_server).to receive(:resource).and_return(instance_double(LanternResource, representative_server: instance_double(described_class, primary?: false)))
      expect(lantern_server.doing_pitr?).to be(true)
    end
  end

  describe "#vm" do
    it "returns gcp_vm" do
      expect(lantern_server.vm).to eq(lantern_server.gcp_vm)
    end
  end

  describe "#hostname" do
    it "returns domain" do
      expect(lantern_server).to receive(:domain).and_return("db.lantern.dev").at_least(:once)
      expect(lantern_server.hostname).to eq("db.lantern.dev")
    end

    it "returns vm host if not temp" do
      expect(lantern_server).to receive(:domain).and_return(nil).at_least(:once)
      expect(vm.sshable).to receive(:host).and_return("1.1.1.1").at_least(:once)
      expect(lantern_server.hostname).to eq("1.1.1.1")
    end

    it "returns nil if vm host is temp" do
      expect(lantern_server).to receive(:domain).and_return(nil).at_least(:once)
      expect(vm.sshable).to receive(:host).and_return("temp_111").at_least(:once)
      expect(lantern_server.hostname).to be_nil
    end

    it "returns nil if vm has no host" do
      expect(lantern_server).to receive(:domain).and_return(nil).at_least(:once)
      expect(vm.sshable).to receive(:host).and_return(nil).at_least(:once)
      expect(lantern_server.hostname).to be_nil
    end
  end

  describe "#connection_string" do
    it "returns nil if no hostname" do
      expect(lantern_server).to receive(:hostname).and_return(nil)
      expect(lantern_server.connection_string).to be_nil
    end

    it "returns correct connection string" do
      expect(lantern_server).to receive(:hostname).and_return("db.lantern.dev")
      expect(lantern_server).to receive(:resource).and_return(instance_double(LanternResource, superuser_password: "pwd123"))
      expect(lantern_server.connection_string).to eq("postgres://postgres:pwd123@db.lantern.dev:6432")
    end
  end

  describe "#configure_hash" do
    it "generates config hash without backup label" do
      timeline = instance_double(LanternTimeline)
      resource = instance_double(LanternResource,
        parent: nil,
        org_id: 0,
        name: "test-db",
        app_env: "test",
        debug: false,
        enable_telemetry: false,
        repl_user: "repl_user",
        repl_password: "repl_password",
        db_name: "postgres",
        db_user: "postgres",
        db_user_password: "pwd123",
        superuser_password: "pwd1234",
        gcp_creds_b64: "test-creds",
        recovery_target_lsn: nil,
        representative_server: lantern_server,
        restore_target: nil)
      expect(Config).to receive(:prom_password).and_return("pwd123").at_least(:once)
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds").at_least(:once)
      expect(Config).to receive(:gcp_creds_logging_b64).and_return("test-creds").at_least(:once)
      expect(timeline).to receive(:generate_walg_config).and_return({gcp_creds_b64: "test-creds-push", walg_gs_prefix: "test-bucket-push"}).at_least(:once)
      expect(lantern_server).to receive(:resource).and_return(resource).at_least(:once)
      expect(lantern_server).to receive(:timeline).and_return(timeline).at_least(:once)
      expect(lantern_server).to receive(:standby?).and_return(false).at_least(:once)
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2").at_least(:once)
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4").at_least(:once)
      expect(lantern_server).to receive(:minor_version).and_return("1").at_least(:once)
      expect(vm).to receive(:boot_image).and_return(Config.gcp_default_image).at_least(:once)

      walg_conf = timeline.generate_walg_config
      expected_conf = JSON.generate({
        enable_coredumps: true,
        skip_deps: false,
        org_id: resource.org_id,
        instance_id: resource.name,
        instance_type: lantern_server.standby? ? "reader" : "writer",
        app_env: resource.app_env,
        enable_debug: resource.debug,
        enable_telemetry: resource.enable_telemetry || "",
        repl_user: resource.repl_user || "",
        repl_password: resource.repl_password || "",
        replication_mode: lantern_server.standby? ? "slave" : "master",
        db_name: resource.db_name || "",
        db_user: resource.db_user || "",
        db_user_password: resource.db_user_password || "",
        postgres_password: resource.superuser_password || "",
        master_host: resource.representative_server.hostname,
        master_port: 5432,
        prom_password: Config.prom_password,
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        gcp_creds_coredumps_b64: Config.gcp_creds_coredumps_b64,
        gcp_creds_logging_b64: Config.gcp_creds_logging_b64,

        container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}",
        postgresql_recover_from_backup: "",
        postgresql_recovery_target_time: resource.restore_target || "",
        postgresql_recovery_target_lsn: resource.recovery_target_lsn || "",
        gcp_creds_walg_b64: walg_conf[:gcp_creds_b64],
        walg_gs_prefix: walg_conf[:walg_gs_prefix],
        gcp_creds_big_query_b64: resource.gcp_creds_b64,
        big_query_dataset: Config.lantern_log_dataset
      })
      expect(lantern_server.configure_hash).to eq(expected_conf)
    end

    it "generates config hash with backup label" do
      timeline = instance_double(LanternTimeline)
      parent = instance_double(LanternResource)
      resource = instance_double(LanternResource,
        parent: parent,
        org_id: 0,
        name: "test-db",
        app_env: "test",
        debug: false,
        enable_telemetry: false,
        repl_user: "repl_user",
        repl_password: "repl_password",
        db_name: "postgres",
        db_user: "postgres",
        db_user_password: "pwd123",
        superuser_password: "pwd1234",
        gcp_creds_b64: "test-creds",
        recovery_target_lsn: nil,
        representative_server: lantern_server,
        restore_target: Time.now)
      expect(Config).to receive(:prom_password).and_return("pwd123").at_least(:once)
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds").at_least(:once)
      expect(Config).to receive(:gcp_creds_logging_b64).and_return("test-creds").at_least(:once)
      expect(timeline).to receive(:latest_backup_label_before_target).and_return("test-label").at_least(:once)
      expect(timeline).to receive(:generate_walg_config).and_return({gcp_creds_b64: "test-creds-push", walg_gs_prefix: "test-bucket-push"}).at_least(:once)
      expect(lantern_server).to receive(:resource).and_return(resource).at_least(:once)
      expect(lantern_server).to receive(:timeline).and_return(timeline).at_least(:once)
      expect(lantern_server).to receive(:standby?).and_return(false).at_least(:once)
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2").at_least(:once)
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4").at_least(:once)
      expect(lantern_server).to receive(:minor_version).and_return("1").at_least(:once)
      expect(vm).to receive(:boot_image).and_return("custom-image").at_least(:once)

      walg_conf = timeline.generate_walg_config
      expected_conf = JSON.generate({
        enable_coredumps: true,
        skip_deps: true,
        org_id: resource.org_id,
        instance_id: resource.name,
        instance_type: lantern_server.standby? ? "reader" : "writer",
        app_env: resource.app_env,
        enable_debug: resource.debug,
        enable_telemetry: resource.enable_telemetry || "",
        repl_user: resource.repl_user || "",
        repl_password: resource.repl_password || "",
        replication_mode: lantern_server.standby? ? "slave" : "master",
        db_name: resource.db_name || "",
        db_user: resource.db_user || "",
        db_user_password: resource.db_user_password || "",
        postgres_password: resource.superuser_password || "",
        master_host: resource.representative_server.hostname,
        master_port: 5432,
        prom_password: Config.prom_password,
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        gcp_creds_coredumps_b64: Config.gcp_creds_coredumps_b64,
        gcp_creds_logging_b64: Config.gcp_creds_logging_b64,
        container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}",
        postgresql_recover_from_backup: "test-label",
        postgresql_recovery_target_time: resource.restore_target || "",
        postgresql_recovery_target_lsn: resource.recovery_target_lsn || "",
        gcp_creds_walg_b64: walg_conf[:gcp_creds_b64],
        walg_gs_prefix: walg_conf[:walg_gs_prefix],
        gcp_creds_big_query_b64: resource.gcp_creds_b64,
        big_query_dataset: Config.lantern_log_dataset
      })
      expect(lantern_server.configure_hash).to eq(expected_conf)
    end

    it "generates config hash with backup label without restore_target" do
      timeline = instance_double(LanternTimeline)
      parent = instance_double(LanternResource)
      resource = instance_double(LanternResource,
        parent: parent,
        org_id: 0,
        name: "test-db",
        app_env: "test",
        debug: false,
        enable_telemetry: false,
        repl_user: "repl_user",
        repl_password: "repl_password",
        db_name: "postgres",
        db_user: "postgres",
        db_user_password: "pwd123",
        superuser_password: "pwd1234",
        gcp_creds_b64: "test-creds",
        recovery_target_lsn: "16/B374D848",
        representative_server: lantern_server,
        restore_target: nil)
      expect(Config).to receive(:prom_password).and_return("pwd123").at_least(:once)
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds").at_least(:once)
      expect(Config).to receive(:gcp_creds_logging_b64).and_return("test-creds").at_least(:once)
      expect(timeline).to receive(:generate_walg_config).and_return({gcp_creds_b64: "test-creds-push", walg_gs_prefix: "test-bucket-push"}).at_least(:once)
      expect(lantern_server).to receive(:resource).and_return(resource).at_least(:once)
      expect(lantern_server).to receive(:timeline).and_return(timeline).at_least(:once)
      expect(lantern_server).to receive(:standby?).and_return(false).at_least(:once)
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2").at_least(:once)
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4").at_least(:once)
      expect(lantern_server).to receive(:minor_version).and_return("1").at_least(:once)
      expect(vm).to receive(:boot_image).and_return("custom-image").at_least(:once)

      walg_conf = timeline.generate_walg_config
      expected_conf = JSON.generate({
        enable_coredumps: true,
        skip_deps: true,
        org_id: resource.org_id,
        instance_id: resource.name,
        instance_type: lantern_server.standby? ? "reader" : "writer",
        app_env: resource.app_env,
        enable_debug: resource.debug,
        enable_telemetry: resource.enable_telemetry || "",
        repl_user: resource.repl_user || "",
        repl_password: resource.repl_password || "",
        replication_mode: lantern_server.standby? ? "slave" : "master",
        db_name: resource.db_name || "",
        db_user: resource.db_user || "",
        db_user_password: resource.db_user_password || "",
        postgres_password: resource.superuser_password || "",
        master_host: resource.representative_server.hostname,
        master_port: 5432,
        prom_password: Config.prom_password,
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        gcp_creds_coredumps_b64: Config.gcp_creds_coredumps_b64,
        gcp_creds_logging_b64: Config.gcp_creds_logging_b64,
        container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}",
        postgresql_recover_from_backup: "LATEST",
        postgresql_recovery_target_time: resource.restore_target || "",
        postgresql_recovery_target_lsn: resource.recovery_target_lsn,
        gcp_creds_walg_b64: walg_conf[:gcp_creds_b64],
        walg_gs_prefix: walg_conf[:walg_gs_prefix],
        gcp_creds_big_query_b64: resource.gcp_creds_b64,
        big_query_dataset: Config.lantern_log_dataset
      })
      expect(lantern_server.configure_hash).to eq(expected_conf)
    end

    it "generates config hash for standby" do
      timeline = instance_double(LanternTimeline)
      parent = instance_double(LanternResource)
      resource = instance_double(LanternResource,
        parent: parent,
        org_id: 0,
        name: "test-db",
        app_env: "test",
        debug: false,
        enable_telemetry: false,
        repl_user: "repl_user",
        repl_password: "repl_password",
        db_name: "postgres",
        db_user: "postgres",
        db_user_password: "pwd123",
        superuser_password: "pwd1234",
        gcp_creds_b64: "test-creds",
        recovery_target_lsn: "16/B374D848",
        representative_server: lantern_server,
        restore_target: Time.now)
      expect(Config).to receive(:prom_password).and_return("pwd123").at_least(:once)
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds").at_least(:once)
      expect(Config).to receive(:gcp_creds_logging_b64).and_return("test-creds").at_least(:once)

      expect(timeline).to receive(:generate_walg_config).and_return({gcp_creds_b64: "test-creds-push", walg_gs_prefix: "test-bucket-push"}).at_least(:once)
      expect(lantern_server).to receive(:resource).and_return(resource).at_least(:once)
      expect(lantern_server).to receive(:timeline).and_return(timeline).at_least(:once)
      expect(lantern_server).to receive(:standby?).and_return(true).at_least(:once)
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2").at_least(:once)
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4").at_least(:once)
      expect(lantern_server).to receive(:minor_version).and_return("1").at_least(:once)
      expect(vm).to receive(:boot_image).and_return("custom-image").at_least(:once)

      walg_conf = timeline.generate_walg_config
      expected_conf = JSON.generate({
        enable_coredumps: true,
        skip_deps: true,
        org_id: resource.org_id,
        instance_id: resource.name,
        instance_type: lantern_server.standby? ? "reader" : "writer",
        app_env: resource.app_env,
        enable_debug: resource.debug,
        enable_telemetry: resource.enable_telemetry || "",
        repl_user: resource.repl_user || "",
        repl_password: resource.repl_password || "",
        replication_mode: lantern_server.standby? ? "slave" : "master",
        db_name: resource.db_name || "",
        db_user: resource.db_user || "",
        db_user_password: resource.db_user_password || "",
        postgres_password: resource.superuser_password || "",
        master_host: resource.representative_server.hostname,
        master_port: 5432,
        prom_password: Config.prom_password,
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        gcp_creds_coredumps_b64: Config.gcp_creds_coredumps_b64,
        gcp_creds_logging_b64: Config.gcp_creds_logging_b64,

        container_image: "#{Config.gcr_image}:lantern-#{lantern_server.lantern_version}-extras-#{lantern_server.extras_version}-minor-#{lantern_server.minor_version}",
        postgresql_recover_from_backup: "LATEST",
        postgresql_recovery_target_time: "",
        postgresql_recovery_target_lsn: "",
        gcp_creds_walg_b64: walg_conf[:gcp_creds_b64],
        walg_gs_prefix: walg_conf[:walg_gs_prefix],
        gcp_creds_big_query_b64: resource.gcp_creds_b64,
        big_query_dataset: Config.lantern_log_dataset
      })
      expect(lantern_server.configure_hash).to eq(expected_conf)
    end
  end

  describe "#update_walg_creds" do
    it "calls update_env on vm" do
      timeline = instance_double(LanternTimeline)
      expect(timeline).to receive(:generate_walg_config).and_return({gcp_creds_b64: "test-creds-push", walg_gs_prefix: "test-bucket-push"}).at_least(:once)
      expect(lantern_server).to receive(:timeline).and_return(timeline).at_least(:once)
      walg_config = timeline.generate_walg_config
      expect(vm.sshable).to receive(:cmd).with("sudo lantern/bin/update_env", stdin: JSON.generate([
        ["WALG_GS_PREFIX", walg_config[:walg_gs_prefix]],
        ["GOOGLE_APPLICATION_CREDENTIALS_WALG_B64", walg_config[:gcp_creds_b64]],
        ["POSTGRESQL_RECOVER_FROM_BACKUP", ""]
      ]))

      expect { lantern_server.update_walg_creds }.not_to raise_error
    end
  end

  describe "#container_image" do
    it "returns correct image" do
      expect(Config).to receive(:gcr_image).and_return("test-image")
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2")
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4")
      expect(lantern_server).to receive(:minor_version).and_return("2")
      expect(lantern_server.container_image).to eq("test-image:lantern-0.2.2-extras-0.1.4-minor-2")
    end
  end

  describe "Lsn monitor" do
    it "fails to initiate a new health monitor session" do
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "setup domain")).at_least(:once).at_least(:once)
      expect { lantern_server.init_health_monitor_session }.to raise_error "server is not ready to initialize session"
    end

    it "initiates a new health monitor session" do
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(lantern_server.init_health_monitor_session).to eq({db_connection: nil})
    end

    it "checks pulse" do
      session = {
        db_connection: DB
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }

      expect(lantern_server).to receive(:destroy_set?).and_return(false)
      expect(lantern_server).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(lantern_server).not_to receive(:incr_checkup)
      lantern_server.check_pulse(session: session, previous_pulse: pulse)
    end

    it "checks pulse on primary" do
      session = {
        db_connection: DB
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }

      expect(lantern_server).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:destroy_set?).and_return(false)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(lantern_server).to receive(:primary?).and_return(true)
      expect(lantern_server).not_to receive(:incr_checkup)
      lantern_server.check_pulse(session: session, previous_pulse: pulse)
    end

    it "increments checkup semaphore if pulse is down for a while" do
      session = {
        db_connection: instance_double(Sequel::Postgres::Database)
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }

      expect(lantern_server).to receive(:display_state).and_return("running").at_least(:once)
      expect(lantern_server).to receive(:destroy_set?).and_return(false)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait")).at_least(:once)
      expect(session[:db_connection]).to receive(:[]).and_raise(Sequel::DatabaseConnectionError)
      expect(lantern_server).to receive(:incr_checkup)
      lantern_server.check_pulse(session: session, previous_pulse: pulse)
    end

    it "does not check the pulse if destroying" do
      session = {
        db_connection: instance_double(Sequel::Postgres::Database)
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      expect(lantern_server).to receive(:destroy_set?).and_return(true)
      lantern_server.check_pulse(session: session, previous_pulse: pulse)
    end

    it "does not check the pulse if strand label is destroy" do
      session = {
        db_connection: instance_double(Sequel::Postgres::Database)
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      expect(lantern_server).to receive(:destroy_set?).and_return(false)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "destroy"))
      lantern_server.check_pulse(session: session, previous_pulse: pulse)
    end

    it "does not check the pulse if not running" do
      session = {
        db_connection: instance_double(Sequel::Postgres::Database)
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      expect(lantern_server).to receive(:display_state).and_return("stopped")
      expect(lantern_server).to receive(:destroy_set?).and_return(false)
      expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      lantern_server.check_pulse(session: session, previous_pulse: pulse)
    end

    it "does not check the pulse if strand does not exist" do
      session = {
        db_connection: instance_double(Sequel::Postgres::Database)
      }
      pulse = {
        reading: "down",
        reading_rpt: 5,
        reading_chg: Time.now - 30
      }
      expect(lantern_server).to receive(:destroy_set?).and_return(false)
      expect(lantern_server).to receive(:strand).and_return(nil)
      lantern_server.check_pulse(session: session, previous_pulse: pulse)
    end
  end

  describe "#prewarm_indexes" do
    it "calls prewarm_indexes with specified query" do
      query = <<SQL
    SELECT i.relname, pg_prewarm(i.relname::text)
FROM pg_class t
JOIN pg_index ix ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN pg_am a ON i.relam = a.oid
JOIN pg_namespace n ON n.oid = i.relnamespace
WHERE a.amname = 'lantern_hnsw';
SQL
      expect(lantern_server.prewarm_indexes_query).to eq(query)
    end
  end

  describe "#list_all_databases" do
    it "returns list of all databases" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo docker compose -f /var/lib/lantern/docker-compose.yaml exec postgresql psql -U postgres -P \"footer=off\" -c 'SELECT datname from pg_database' | tail -n +3 | grep -v 'template0' | grep -v 'template1'").and_return("postgres\ndb2\n")
      expect(lantern_server.list_all_databases).to eq(["postgres", "db2"])
    end
  end

  describe "#get_vm_image" do
    it "returns default image" do
      allow(described_class).to receive(:get_vm_image).and_call_original
      api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(api)
      expect(api).to receive(:get_image).and_return(nil)
      expect(described_class.get_vm_image("0.2.7", "0.1.5", "1")).to eq(Config.gcp_default_image)
    end

    it "returns custom image" do
      allow(described_class).to receive(:get_vm_image).and_call_original
      api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(api)
      expect(api).to receive(:get_image).and_return({"resource_name" => "custom-image"})
      expect(described_class.get_vm_image("0.2.7", "0.1.5", "1")).to eq("custom-image")
    end
  end

  describe "#change_replication_mode" do
    it "changes to master without env" do
      time = Time.new
      expect(Time).to receive(:new).and_return(time)
      expect(lantern_server).to receive(:update).with(timeline_access: "push", representative_at: time)
      lantern_server.change_replication_mode("master", update_env: false)
    end

    it "changes to master" do
      time = Time.new
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/update_env", stdin: JSON.generate([
        ["POSTGRESQL_REPLICATION_MODE", "master"],
        ["INSTANCE_TYPE", "writer"],
        ["POSTGRESQL_RECOVER_FROM_BACKUP", ""]
      ]))
      expect(Time).to receive(:new).and_return(time)
      expect(lantern_server).to receive(:update).with(timeline_access: "push", representative_at: time)
      lantern_server.change_replication_mode("master", update_env: true)
    end

    it "changes to slave" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/update_env", stdin: JSON.generate([
        ["POSTGRESQL_REPLICATION_MODE", "slave"],
        ["INSTANCE_TYPE", "reader"],
        ["POSTGRESQL_RECOVER_FROM_BACKUP", ""]
      ]))
      expect(lantern_server).to receive(:update).with(timeline_access: "fetch", representative_at: nil)
      lantern_server.change_replication_mode("slave")
    end
  end

  describe "#autoresize_disk" do
    it "resizes data disk by 50%" do
      expect(lantern_server).to receive(:target_storage_size_gib).and_return(50).at_least(:once)
      expect(lantern_server).to receive(:max_storage_autoresize_gib).and_return(100).at_least(:once)
      expect(lantern_server).to receive(:update).with(target_storage_size_gib: 75)
      expect(lantern_server.vm).to receive(:update).with(storage_size_gib: 75)
      expect(lantern_server).to receive(:incr_update_storage_size)
      expect { lantern_server.autoresize_disk }.not_to raise_error
    end

    it "resizes data disk by max" do
      expect(lantern_server).to receive(:target_storage_size_gib).and_return(50).at_least(:once)
      expect(lantern_server).to receive(:max_storage_autoresize_gib).and_return(70).at_least(:once)
      expect(lantern_server).to receive(:update).with(target_storage_size_gib: 70)
      expect(lantern_server.vm).to receive(:update).with(storage_size_gib: 70)
      expect(lantern_server).to receive(:incr_update_storage_size)
      expect { lantern_server.autoresize_disk }.not_to raise_error
    end

    it "does nothing" do
      expect(lantern_server).to receive(:target_storage_size_gib).and_return(80).at_least(:once)
      expect(lantern_server).to receive(:max_storage_autoresize_gib).and_return(70).at_least(:once)
      expect(lantern_server).not_to receive(:incr_update_storage_size)
      expect { lantern_server.autoresize_disk }.not_to raise_error
    end
  end

  describe "#query_string" do
    it "requires ssl if there's domain" do
      expect(lantern_server).to receive(:domain).and_return("db.lantern.dev").at_least(:once)
      expect(lantern_server.query_string).to eq("sslmode=require")
    end

    it "does not add query string if there's no domain" do
      expect(lantern_server).to receive(:domain).and_return(nil).at_least(:once)
      expect(lantern_server.query_string).to be_nil
    end
  end
end
