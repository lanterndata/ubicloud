# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternServerNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternServerNexus", label: "start")) }

  let(:sshable) { instance_double(Sshable) }

  let(:lantern_server) {
    instance_double(
      LanternServer,
      org_id: 0,
      name: "test",
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      gcp_vm: instance_double(
        GcpVm,
        id: "104b0033-b3f6-8214-ae27-0cd3cef18ce4",
        sshable: sshable,
        domain: nil
      ),
      timeline: instance_double(
        LanternTimeline,
        id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
        gcp_creds_b64: "test-creds",
        service_account_name: "test-sa",
        bucket_name: "test-bucket"
      )
    )
  }

  before do
    allow(nx).to receive(:lantern_server).and_return(lantern_server)
  end

  describe ".assemble" do
    it "fails to create lantern server if no project found" do
      expect {
        described_class.assemble(
          project_id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0"
        )
      }.to raise_error "No existing parent"
    end

    it "raises if gcr credentials are not provided" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return(nil)
      expect { nx.setup_docker_stack }.to raise_error "GCP_CREDS_GCR_B64 is required to setup docker stack for Lantern"
    end

    it "creates lantern server and generate user password" do
      postgres_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }

      st = described_class.assemble(
        project_id: postgres_project.id,
        lantern_version: "0.2.0",
        extras_version: "0.1.3",
        minor_version: "2",
        org_id: 0,
        name: "instance-test",
        instance_type: "writer",
        db_name: "testdb",
        target_vm_size: "n1-standard-2",
        db_user: "test",
        app_env: "test",
        postgres_password: "test-pg-pass",
        repl_password: "test-repl-pass",
        enable_telemetry: true,
        enable_debug: true
      )
      lantern_server = LanternServer[st.id]
      expect(lantern_server).not_to be_nil
      expect(lantern_server.db_user_password).not_to be_nil
    end

    it "creates lantern server as writer from backup" do
      postgres_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }

      parent_timeline = LanternTimeline.create_with_id(gcp_creds_b64: "test-creds-pull")
      LanternServer.create_with_id(timeline_id: parent_timeline.id, db_user: "lantern", db_name: "testdb", repl_user: "repl_user", repl_password: "repl_password", db_user_password: "pwd123", postgres_password: "pwd123", project_id: postgres_project.id, target_vm_size: "n1-standard-2", target_storage_size_gib: 100)

      expect {
        described_class.assemble(
          project_id: postgres_project.id,
          lantern_version: "0.2.0",
          extras_version: "0.1.3",
          minor_version: "2",
          org_id: 0,
          name: "instance-test",
          instance_type: "writer",
          db_name: "testdb",
          target_vm_size: "n1-standard-2",
          db_user: "test",
          app_env: "test",
          postgres_password: "test-pg-pass",
          repl_password: "test-repl-pass",
          enable_telemetry: true,
          enable_debug: true,
          timeline_id: parent_timeline.id,
          restore_target: Time.now
        )
      }.not_to raise_error
    end

    it "creates lantern server and vm with sshable" do
      postgres_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }

      st = described_class.assemble(
        project_id: postgres_project.id,
        lantern_version: "0.2.0",
        extras_version: "0.1.3",
        minor_version: "2",
        org_id: 0,
        name: "instance-test",
        instance_type: "writer",
        db_name: "testdb",
        target_vm_size: "n1-standard-2",
        db_user: "test",
        app_env: "test",
        db_user_password: "test-pass",
        postgres_password: "test-pg-pass",
        repl_password: "test-repl-pass",
        enable_telemetry: true,
        enable_debug: true
      )
      lantern_server = LanternServer[st.id]
      expect(lantern_server).not_to be_nil
      expect(lantern_server.gcp_vm).not_to be_nil
      expect(lantern_server.gcp_vm.sshable).not_to be_nil

      expect(lantern_server.app_env).to eq("test")
      expect(lantern_server.db_user).to eq("test")
      expect(lantern_server.db_user_password).to eq("test-pass")
      expect(lantern_server.postgres_password).to eq("test-pg-pass")
      expect(lantern_server.repl_password).to eq("test-repl-pass")
      expect(lantern_server.enable_telemetry).to be(true)
      expect(lantern_server.debug).to be(true)
      expect(lantern_server.lantern_version).to eq("0.2.0")
      expect(lantern_server.extras_version).to eq("0.1.3")
      expect(lantern_server.minor_version).to eq("2")
      expect(lantern_server.org_id).to eq(0)
      expect(lantern_server.name).to eq("instance-test")
      expect(lantern_server.instance_type).to eq("writer")
      expect(lantern_server.db_name).to eq("testdb")
      expect(lantern_server.db_user).to eq("test")
      expect(lantern_server.gcp_vm.cores).to eq(2)
    end
  end

  describe "#start" do
    before do
      allow(Config).to receive(:gcp_creds_gcr_b64).and_return("test-token")
    end

    it "naps if vm not ready" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "update sshable host and hops" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(lantern_server).to receive(:incr_initial_provisioning)
      expect { nx.start }.to hop("bootstrap_rhizome")
    end

    describe "#bootstrap_rhizome" do
      it "buds a bootstrap rhizome process" do
        expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "lantern", "subject_id" => lantern_server.gcp_vm.id, "user" => "lantern"})
        expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
      end
    end

    describe "#wait_bootstrap_rhizome" do
      before { expect(nx).to receive(:reap) }

      it "hops to setup_docker_stack if there are no sub-programs running" do
        expect(nx).to receive(:leaf?).and_return true

        expect { nx.wait_bootstrap_rhizome }.to hop("setup_docker_stack")
      end

      it "donates if there are sub-programs running" do
        expect(nx).to receive(:leaf?).and_return false
        expect(nx).to receive(:donate).and_call_original

        expect { nx.wait_bootstrap_rhizome }.to nap(0)
      end
    end

    describe "#setup_docker_stack" do
      it "Calls add_domain if gcp_vm has domain after setup_docker_stack" do
        allow(lantern_server).to receive(:org_id)
        allow(lantern_server).to receive(:name)
        allow(lantern_server).to receive(:instance_type)
        allow(lantern_server).to receive(:db_name)
        allow(lantern_server).to receive(:db_user)
        allow(lantern_server).to receive(:db_user_password)
        allow(lantern_server).to receive(:postgres_password)
        allow(lantern_server).to receive(:master_host)
        allow(lantern_server).to receive(:master_port)
        allow(lantern_server).to receive(:lantern_version)
        allow(lantern_server).to receive(:extras_version)
        allow(lantern_server).to receive(:minor_version)
        allow(lantern_server).to receive(:app_env)
        allow(lantern_server).to receive(:debug)
        allow(lantern_server).to receive(:enable_telemetry)
        allow(lantern_server).to receive(:repl_password)
        allow(lantern_server).to receive(:repl_user)
        allow(lantern_server.gcp_vm.sshable).to receive(:cmd).and_return("Succeeded")
        expect(lantern_server.gcp_vm).to receive(:domain).and_return "test.lantern.dev"
        expect(lantern_server).to receive(:incr_add_domain) do nx.incr_add_domain end
        expect { nx.setup_docker_stack }.to hop("wait_db_available")
        expect(nx).to receive(:available?).and_return(false)
        expect { nx.wait_db_available }.to nap(10)
        expect(nx).to receive(:available?).and_return(true)
        expect { nx.wait_db_available }.to hop("wait")
        expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
        expect { nx.wait }.to hop("add_domain")
      end

      it "Sets up correct walg creds" do
        expect(lantern_server).to receive(:instance_type).and_return("writer")
        expect(lantern_server).to receive(:standby?).and_return(false).exactly(3).times
        expect(lantern_server).to receive(:app_env).and_return("production")
        expect(lantern_server).to receive(:debug).and_return(false)
        expect(lantern_server).to receive(:enable_telemetry).and_return(true)
        expect(lantern_server).to receive(:repl_user).and_return("repl_user")
        expect(lantern_server).to receive(:repl_password).and_return("repl_password")
        expect(lantern_server).to receive(:db_name).and_return("testdb")
        expect(lantern_server).to receive(:db_user).and_return("lantern")
        expect(lantern_server).to receive(:db_user_password).and_return("pwd123")
        expect(lantern_server).to receive(:postgres_password).and_return("pwd1234")
        expect(lantern_server).to receive(:master_host).and_return("127.0.0.1")
        expect(lantern_server).to receive(:master_port).and_return("5432")
        expect(lantern_server).to receive(:lantern_version).and_return("0.2.2")
        expect(lantern_server).to receive(:extras_version).and_return("0.1.4")
        expect(lantern_server).to receive(:minor_version).and_return("1")
        restore_target = Time.now
        expect(lantern_server).to receive(:restore_target).and_return(restore_target).exactly(3).times

        parent_timeline = instance_double(LanternTimeline, bucket_name: "test-bucket-pull")
        expect(lantern_server.timeline).to receive(:generate_walg_config).and_return({walg_gs_push_prefix: "test-bucket", gcp_creds_walg_push_b64: "test-creds", gcp_creds_walg_pull_b64: "test-creds-pull", walg_gs_pull_prefix: parent_timeline.bucket_name})
        expect(lantern_server.timeline).to receive(:parent).and_return(parent_timeline).twice
        expect(parent_timeline).to receive(:latest_backup_label_before_target).and_return("test-label")
        expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("NotStarted")
        expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
          configure_hash = JSON.parse(stdin)
          expect(configure_hash["replication_mode"]).to eq("master")
          expect(configure_hash["gcp_creds_walg_push_b64"]).to eq("test-creds")
          expect(configure_hash["walg_gs_push_prefix"]).to eq("test-bucket")

          expect(configure_hash["gcp_creds_walg_pull_b64"]).to eq("test-creds-pull")
          expect(configure_hash["walg_gs_pull_prefix"]).to eq(parent_timeline.bucket_name)

          expect(configure_hash["postgresql_recover_from_backup"]).to eq("test-label")
          expect(configure_hash["postgresql_recovery_target_time"]).to eq(JSON.parse(JSON.dump(restore_target)))
        end

        expect { nx.setup_docker_stack }.to nap(5)
      end
    end

    it "creates lantern server as reader instance" do
      expect(lantern_server.timeline).to receive(:parent).and_return(nil).twice
      expect(lantern_server.timeline).to receive(:generate_walg_config).and_return({}).twice
      expect(lantern_server).to receive(:standby?).and_return(true).exactly(4).times
      expect(lantern_server).to receive(:instance_type).and_return("reader").twice
      expect(lantern_server).to receive(:app_env).and_return("production").twice
      expect(lantern_server).to receive(:debug).and_return(false).twice
      expect(lantern_server).to receive(:enable_telemetry).and_return(true).twice
      expect(lantern_server).to receive(:repl_user).and_return("repl_user").twice
      expect(lantern_server).to receive(:repl_password).and_return("repl_user").twice
      expect(lantern_server).to receive(:db_name).and_return("testdb").twice
      expect(lantern_server).to receive(:db_user).and_return("lantern").twice
      expect(lantern_server).to receive(:db_user_password).and_return("pwd123").twice
      expect(lantern_server).to receive(:postgres_password).and_return("pwd1234").twice
      expect(lantern_server).to receive(:master_host).and_return("127.0.0.1").twice
      expect(lantern_server).to receive(:master_port).and_return("5432").twice
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2").twice
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4").twice
      expect(lantern_server).to receive(:minor_version).and_return("1").twice

      # Start configure
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("NotStarted")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        expect(JSON.parse(stdin)["replication_mode"]).to eq("slave")
      end
      expect { nx.setup_docker_stack }.to nap(5)

      # Running configure
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("Running")
      expect { nx.setup_docker_stack }.to nap(5)

      # Fail configure
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("Failed")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        expect(JSON.parse(stdin)["replication_mode"]).to eq("slave")
      end
      expect { nx.setup_docker_stack }.to nap(5)

      # Succeed configure
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("Succeeded")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_lantern").and_return(nil)
      expect { nx.setup_docker_stack }.to hop("wait_db_available")
    end

    it "creates lantern server as writer instance" do
      expect(lantern_server.timeline).to receive(:parent).and_return(instance_double(LanternTimeline))
      expect(lantern_server.timeline).to receive(:generate_walg_config).and_return({walg_gs_push_prefix: "test-bucket", gcp_creds_walg_push_b64: "test-creds"})
      expect(lantern_server).to receive(:instance_type).and_return("writer")
      expect(lantern_server).to receive(:standby?).and_return(false).exactly(3).times
      expect(lantern_server).to receive(:app_env).and_return("production")
      expect(lantern_server).to receive(:debug).and_return(false)
      expect(lantern_server).to receive(:enable_telemetry).and_return(true)
      expect(lantern_server).to receive(:repl_user).and_return("repl_user")
      expect(lantern_server).to receive(:repl_password).and_return("repl_user")
      expect(lantern_server).to receive(:db_name).and_return("testdb")
      expect(lantern_server).to receive(:db_user).and_return("lantern")
      expect(lantern_server).to receive(:db_user_password).and_return("pwd123")
      expect(lantern_server).to receive(:postgres_password).and_return("pwd1234")
      expect(lantern_server).to receive(:master_host).and_return("127.0.0.1")
      expect(lantern_server).to receive(:master_port).and_return("5432")
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2")
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4")
      expect(lantern_server).to receive(:minor_version).and_return("1")
      expect(lantern_server).to receive(:restore_target).and_return(nil).twice
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("NotStarted")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        configure_hash = JSON.parse(stdin)
        expect(configure_hash["replication_mode"]).to eq("master")
        expect(configure_hash["gcp_creds_walg_push_b64"]).to eq("test-creds")
        expect(configure_hash["walg_gs_push_prefix"]).to eq("test-bucket")
      end
      expect { nx.setup_docker_stack }.to nap(5)
    end

    it "creates lantern server as writer from backup with LATEST label" do
      parent_timeline = LanternTimeline.create_with_id(gcp_creds_b64: "test-creds-pull")
      expect(lantern_server.timeline).to receive(:parent).and_return(parent_timeline)
      expect(lantern_server.timeline).to receive(:generate_walg_config).and_return({walg_gs_push_prefix: "test-bucket", gcp_creds_walg_push_b64: "test-creds", gcp_creds_walg_pull_b64: "test-creds-pull", walg_gs_pull_prefix: parent_timeline.bucket_name})
      expect(lantern_server).to receive(:instance_type).and_return("writer")
      expect(lantern_server).to receive(:standby?).and_return(false).exactly(3).times
      expect(lantern_server).to receive(:app_env).and_return("production")
      expect(lantern_server).to receive(:debug).and_return(false)
      expect(lantern_server).to receive(:enable_telemetry).and_return(true)
      expect(lantern_server).to receive(:repl_user).and_return("repl_user")
      expect(lantern_server).to receive(:repl_password).and_return("repl_password")
      expect(lantern_server).to receive(:db_name).and_return("testdb")
      expect(lantern_server).to receive(:db_user).and_return("lantern")
      expect(lantern_server).to receive(:db_user_password).and_return("pwd123")
      expect(lantern_server).to receive(:postgres_password).and_return("pwd1234")
      expect(lantern_server).to receive(:master_host).and_return("127.0.0.1")
      expect(lantern_server).to receive(:master_port).and_return("5432")
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2")
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4")
      expect(lantern_server).to receive(:minor_version).and_return("1")

      expect(lantern_server).to receive(:restore_target).and_return(nil).twice
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("NotStarted")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        configure_hash = JSON.parse(stdin)
        expect(configure_hash["replication_mode"]).to eq("master")
        expect(configure_hash["gcp_creds_walg_push_b64"]).to eq("test-creds")
        expect(configure_hash["walg_gs_push_prefix"]).to eq("test-bucket")

        expect(configure_hash["gcp_creds_walg_pull_b64"]).to eq("test-creds-pull")
        expect(configure_hash["walg_gs_pull_prefix"]).to eq(parent_timeline.bucket_name)

        expect(configure_hash["postgresql_recover_from_backup"]).to eq("LATEST")
      end

      expect { nx.setup_docker_stack }.to nap(5)
    end
  end

  describe "#update_lantern_extension" do
    it "updates lantern extension" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_update_lantern_extension)
      lantern_server.update(lantern_version: "0.2.0")
      nx.incr_update_rhizome
      nx.incr_update_lantern_extension
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { nx.wait }.to hop("update_rhizome")
      expect { nx.wait_update_rhizome }.to hop("update_lantern_extension")

      expect(lantern_server).to receive(:lantern_version).and_return("0.2.0")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        expect(JSON.parse(stdin)["version"]).to eq("0.2.0")
      end

      expect { nx.update_lantern_extension }.to hop("wait_db_available")
    end

    it "updates lantern_extras extension" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_update_extras_extension)
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      lantern_server.update(lantern_version: "0.1.1")
      nx.incr_update_rhizome
      nx.incr_update_extras_extension
      expect { nx.wait }.to hop("update_rhizome")
      expect { nx.wait_update_rhizome }.to hop("update_extras_extension")

      expect(lantern_server).to receive(:extras_version).and_return("0.1.1")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        expect(JSON.parse(stdin)["version"]).to eq("0.1.1")
      end

      expect { nx.update_extras_extension }.to hop("wait_db_available")
    end

    it "updates container image" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_update_image)
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      lantern_server.update(lantern_version: "0.1.1", minor_version: "2")
      nx.incr_update_rhizome
      nx.incr_update_image
      expect { nx.wait }.to hop("update_rhizome")
      expect { nx.wait_update_rhizome }.to hop("update_image")

      expect(lantern_server).to receive(:lantern_version).and_return("0.2.2")
      expect(lantern_server).to receive(:extras_version).and_return("0.1.4")
      expect(lantern_server).to receive(:minor_version).and_return("2")
      expect(Config).to receive(:gcr_image).and_return("lanterndata/lantern")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        expect(JSON.parse(stdin)["container_image"]).to eq("lanterndata/lantern:lantern-0.2.2-extras-0.1.4-minor-2")
      end

      expect { nx.update_image }.to hop("wait_db_available")
    end

    it "fails to add domain" do
      expect(lantern_server.gcp_vm.sshable).to receive(:host).and_return("1.1.1.1")
      cf_client = instance_double(Dns::Cloudflare)
      expect(Dns::Cloudflare).to receive(:new).and_return(cf_client)
      expect(cf_client).to receive(:upsert_dns_record).and_raise
      allow(lantern_server.gcp_vm).to receive(:update).with(domain: nil)
      expect { nx.add_domain }.to hop("wait")
    end

    it "adds domain and setup ssl" do
      allow(lantern_server).to receive(:update)
      allow(lantern_server).to receive(:incr_add_domain)
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_add_domain
      expect { nx.wait }.to hop("add_domain")
      expect(lantern_server.gcp_vm.sshable).to receive(:host).and_return("1.1.1.1")
      cf_client = instance_double(Dns::Cloudflare)
      expect(Dns::Cloudflare).to receive(:new).and_return(cf_client)
      expect(lantern_server.gcp_vm).to receive(:domain).and_return("test.lantern.dev")
      expect(cf_client).to receive(:upsert_dns_record).with("test.lantern.dev", "1.1.1.1")
      expect { nx.add_domain }.to hop("setup_ssl")
    end

    it "setups ssl" do
      expect(lantern_server.gcp_vm).to receive(:domain).and_return("example.com")
      expect(Config).to receive(:cf_token).and_return("test_cf_token")
      expect(Config).to receive(:cf_zone_id).and_return("test_zone_id")
      expect(Config).to receive(:lantern_dns_email).and_return("test@example.com")
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        data = JSON.parse(stdin)
        expect(data["dns_token"]).to eq("test_cf_token")
        expect(data["dns_zone_id"]).to eq("test_zone_id")
        expect(data["dns_email"]).to eq("test@example.com")
        expect(data["domain"]).to eq("example.com")
      end

      expect { nx.setup_ssl }.to hop("wait_db_available")
    end

    it "does not update user password if user is postgres" do
      expect(lantern_server).to receive(:db_user).and_return("postgres")
      expect { nx.update_user_password }.to hop("wait")
    end

    it "updates user password" do
      expect(lantern_server).to receive(:db_user).and_return("lantern").exactly(3).times
      expect(lantern_server).to receive(:db_user_password).and_return("pwd")
      expect(lantern_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_user_password }.to hop("wait")
    end

    it "destroys domain" do
      cf_client = instance_double(Dns::Cloudflare)
      expect(Dns::Cloudflare).to receive(:new).and_return(cf_client)
      expect(lantern_server.gcp_vm).to receive(:domain).and_return("example.com")
      expect(cf_client).to receive(:delete_dns_record).with("example.com")
      nx.destroy_domain
    end

    it "updates rhizome" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_rhizome
      expect { nx.wait }.to hop("update_rhizome")
      expect { nx.update_rhizome }.to hop("wait_update_rhizome")
    end

    it "updates lantern extension after update_rhizome" do
      nx.incr_update_lantern_extension
      expect { nx.wait_update_rhizome }.to hop("update_lantern_extension")
    end

    it "updates extras extension after update_rhizome" do
      nx.incr_update_extras_extension
      expect { nx.wait_update_rhizome }.to hop("update_extras_extension")
    end

    it "updates image after update_rhizome" do
      nx.incr_update_image
      expect { nx.wait_update_rhizome }.to hop("update_image")
    end

    it "waits after update_rhizome" do
      expect { nx.wait_update_rhizome }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to update_user_password" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_user_password
      expect { nx.wait }.to hop("update_user_password")
    end

    it "hops to restart_server" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_restart_server
      expect { nx.wait }.to hop("restart_server")
    end

    it "hops to start_server" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_start_server
      expect { nx.wait }.to hop("start_server")
    end

    it "hops to stop_server" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_stop_server
      expect { nx.wait }.to hop("stop_server")
    end

    it "hops to add_domain" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_add_domain
      expect { nx.wait }.to hop("add_domain")
    end

    it "hops to setup_ssl" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_setup_ssl
      expect { nx.wait }.to hop("setup_ssl")
    end

    it "hops to update_rhizome" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_rhizome
      expect { nx.wait }.to hop("update_rhizome")
    end

    it "hops to destroy" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to update_storage_size" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_storage_size
      expect { nx.wait }.to hop("update_storage_size")
    end

    it "hops to update_vm_size" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_vm_size
      expect { nx.wait }.to hop("update_vm_size")
    end

    it "hops to wait_db_available" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "updating"))
      expect { nx.wait }.to hop("wait_db_available")
    end

    it "naps 30" do
      expect(lantern_server.gcp_vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#wait_db_available" do
    it "hops to wait after initial provisioning" do
      expect(lantern_server).to receive(:run_query)
      expect(lantern_server.gcp_vm.sshable).to receive(:invalidate_cache_entry)
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect { nx.wait_db_available }.to hop("wait")
    end

    it "updates memory limits" do
      expect(nx).to receive(:when_update_memory_limits_set?).and_yield
      expect(lantern_server).to receive(:run_query)
      expect(lantern_server.gcp_vm.sshable).to receive(:invalidate_cache_entry)
      expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("sudo lantern/bin/update_memory_limits")
      expect { nx.wait_db_available }.to hop("wait")
    end
  end

  describe "#available" do
    it "marks as available" do
      expect(lantern_server).to receive(:run_query)
      expect(lantern_server.gcp_vm.sshable).to receive(:invalidate_cache_entry)
      expect(nx.available?).to be(true)
    end

    it "marks as unavailable" do
      expect(lantern_server).to receive(:run_query).and_raise "err"
      expect(lantern_server.gcp_vm.sshable).to receive(:invalidate_cache_entry)
      expect(nx.available?).to be(false)
    end
  end

  describe "#destroy" do
    it "destroys lantern_server and gcp_vm" do
      allow(lantern_server.gcp_vm).to receive(:incr_destroy)
      expect(lantern_server.gcp_vm).to receive(:domain).and_return(nil)
      project = instance_double(Project)
      expect(lantern_server).to receive(:projects).and_return([project])
      expect(lantern_server).to receive(:dissociate_with_project).with(project)
      expect(lantern_server).to receive(:destroy)
      expect(lantern_server.timeline).to receive(:incr_destroy)
      expect { nx.destroy }.to exit({"msg" => "lantern server was deleted"})
    end

    it "destroys lantern_server, gcp_vm and domain" do
      allow(lantern_server.gcp_vm).to receive(:incr_destroy)
      expect(lantern_server.gcp_vm).to receive(:domain).and_return("example.com")
      project = instance_double(Project)
      expect(lantern_server).to receive(:projects).and_return([project])
      expect(lantern_server).to receive(:dissociate_with_project).with(project)
      expect(nx).to receive(:destroy_domain)
      expect(lantern_server).to receive(:destroy)
      expect(lantern_server.timeline).to receive(:incr_destroy)
      expect { nx.destroy }.to exit({"msg" => "lantern server was deleted"})
    end
  end

  describe "#start,stop,restart" do
    it "starts gcp_vm and hop to wait_db_available" do
      expect(nx).to receive(:decr_start_server)
      expect(lantern_server.gcp_vm).to receive(:incr_start_vm)
      expect { nx.start_server }.to hop("wait_db_available")
    end

    it "stops gcp_vm and hop to wait" do
      expect(nx).to receive(:decr_stop_server)
      expect(lantern_server.gcp_vm).to receive(:incr_stop_vm)
      expect { nx.stop_server }.to hop("wait")
    end

    it "restarts gcp_vm and hop to wait" do
      expect(nx).to receive(:decr_restart_server)
      expect(nx).to receive(:incr_stop_server)
      expect(nx).to receive(:incr_start_server)
      expect { nx.restart_server }.to hop("wait")
    end
  end

  describe "#update_storage_size" do
    it "calls update_storage_size on gcp_vm" do
      expect(lantern_server.gcp_vm).to receive(:incr_update_storage)
      expect { nx.update_storage_size }.to hop("wait")
    end
  end

  describe "#update_vm_size" do
    it "calls update_vm_size on gcp_vm" do
      expect(lantern_server.gcp_vm).to receive(:incr_update_size)
      expect { nx.update_vm_size }.to hop("wait")
    end
  end
end
