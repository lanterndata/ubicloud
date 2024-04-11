# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternServerNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternServerNexus", label: "start")) }

  let(:sshable) { instance_double(Sshable) }

  let(:lantern_server) {
    instance_double(
      LanternServer,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      domain: nil,
      resource: instance_double(LanternResource,
        org_id: 0,
        name: "test",
        db_name: "postgres",
        db_user: "postgres",
        superuser_password: "pwd123"),
      vm: instance_double(
        GcpVm,
        id: "104b0033-b3f6-8214-ae27-0cd3cef18ce4",
        sshable: sshable
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
    it "fails to create lantern server if no resource found" do
      expect {
        described_class.assemble(
          resource_id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0"
        )
      }.to raise_error "No existing parent"
    end

    it "creates lantern server as primary" do
      project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
      lantern_resource = instance_double(LanternResource,
        name: "test",
        project_id: project.id,
        location: "us-central1")

      expect(LanternResource).to receive(:[]).and_return(lantern_resource)

      st = described_class.assemble(
        resource_id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
        lantern_version: "0.2.0",
        extras_version: "0.1.3",
        minor_version: "2",
        target_vm_size: "n1-standard-2",
        target_storage_size_gib: 50,
        representative_at: Time.now,
        domain: "db.lantern.dev"
      )

      lantern_server = LanternServer[st.id]
      expect(lantern_server).not_to be_nil
    end

    it "creates lantern server as standby" do
      project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
      lantern_resource = instance_double(LanternResource,
        name: "test",
        project_id: project.id,
        location: "us-central1")

      expect(LanternResource).to receive(:[]).and_return(lantern_resource)

      st = described_class.assemble(
        resource_id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
        lantern_version: "0.2.0",
        extras_version: "0.1.3",
        minor_version: "2",
        target_vm_size: "n1-standard-2",
        target_storage_size_gib: 50,
        representative_at: nil,
        domain: nil
      )

      lantern_server = LanternServer[st.id]
      expect(lantern_server).not_to be_nil
    end
  end

  describe "#before_run" do
    it "hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "pops if already in the destroy state and has stack items" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy").at_least(:once)
      frame = {"link" => ["Lantern::LanternServerNexus", "wait"]}
      expect(nx).to receive(:frame).and_return(frame)
      expect(nx.strand).to receive(:stack).and_return([JSON.generate(frame), JSON.generate(frame)]).at_least(:once)
      expect { nx.before_run }.to hop("wait")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy").at_least(:once)
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "naps if vm not ready" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "hops to bootstrap_rhizome" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(lantern_server).to receive(:incr_initial_provisioning)
      expect { nx.start }.to hop("bootstrap_rhizome")
    end
  end

  describe "#update_rhizome" do
    it "updates rhizome" do
      expect(nx).to receive(:decr_update_rhizome)
      expect(nx).to receive(:bud).with(Prog::UpdateRhizome, {"target_folder" => "lantern", "subject_id" => lantern_server.vm.id, "user" => "lantern"})
      expect { nx.update_rhizome }.to hop("wait_update_rhizome")
    end
  end

  describe "#wait_update_rhizome" do
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

    it "naps if no leaf" do
      expect(nx).to receive(:leaf?).and_return(false)
      expect { nx.wait_update_rhizome }.to nap
    end
  end

  describe "#bootstrap_rhizome" do
    it "buds a bootstrap rhizome process" do
      expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "lantern", "subject_id" => lantern_server.vm.id, "user" => "lantern"})
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
    it "raises if gcr credentials are not provided" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return(nil)
      expect { nx.setup_docker_stack }.to raise_error "GCP_CREDS_GCR_B64 is required to setup docker stack for Lantern"
    end

    it "calls setup if not started" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("NotStarted")
      expect(lantern_server).to receive(:configure_hash).and_return("test")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/configure' configure_lantern", stdin: "test")
      expect { nx.setup_docker_stack }.to nap(5)
    end

    it "calls setup if failed" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("Failed")
      expect(lantern_server).to receive(:configure_hash).and_return("test")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/configure' configure_lantern", stdin: "test")
      expect { nx.setup_docker_stack }.to nap(5)
    end

    it "calls add domain after succeeded" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_lantern")
      expect(lantern_server).to receive(:domain).and_return("db.lantern.dev")
      expect(lantern_server).to receive(:incr_add_domain)
      expect { nx.setup_docker_stack }.to hop("wait_db_available")
    end

    it "hop to wait_db_available" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_lantern")
      expect(lantern_server).to receive(:domain).and_return(nil)
      expect { nx.setup_docker_stack }.to hop("wait_db_available")
    end

    it "naps if in progress" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("InProgress")
      expect { nx.setup_docker_stack }.to nap(5)
    end
  end

  describe "#init_sql" do
    it "calls init_sql if not started" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_sql").and_return("NotStarted")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/init_sql' init_sql")
      expect { nx.init_sql }.to nap(5)
    end

    it "calls init_sql if failed" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_sql").and_return("Failed")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/init_sql' init_sql")
      expect { nx.init_sql }.to nap(5)
    end

    it "hops to wait_db_available" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_sql").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean init_sql")
      expect { nx.init_sql }.to hop("wait_db_available")
    end

    it "naps if in progress" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_sql").and_return("InProgress")
      expect { nx.init_sql }.to nap(5)
    end
  end

  describe "#wait_catch_up" do
    it "naps if lag is empty" do
      leader = instance_double(LanternServer)
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(leader).to receive(:run_query).and_return("")
      expect { nx.wait_catch_up }.to nap(30)
    end

    it "naps if lag is too high" do
      leader = instance_double(LanternServer)
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(leader).to receive(:run_query).and_return((81 * 1024 * 1024).to_s)
      expect { nx.wait_catch_up }.to nap(30)
    end

    it "hops to wait_synchronization" do
      leader = instance_double(LanternServer)
      expect(lantern_server).to receive(:update).with({synchronization_status: "ready"})
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(lantern_server.resource).to receive(:ha_type).and_return(LanternResource::HaType::SYNC)
      expect(leader).to receive(:run_query).and_return((1 * 1024 * 1024).to_s)
      expect { nx.wait_catch_up }.to hop("wait_synchronization")
    end

    it "hops to wait" do
      leader = instance_double(LanternServer)
      expect(lantern_server).to receive(:update).with({synchronization_status: "ready"})
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(lantern_server.resource).to receive(:ha_type).and_return(LanternResource::HaType::ASYNC)
      expect(leader).to receive(:run_query).and_return((1 * 1024 * 1024).to_s)
      expect { nx.wait_catch_up }.to hop("wait")
    end
  end

  describe "#wait_synchronization" do
    it "hops to wait if quorum" do
      leader = instance_double(LanternServer)
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(leader).to receive(:run_query).and_return("quorum")
      expect { nx.wait_synchronization }.to hop("wait")
    end

    it "hops to wait if sync" do
      leader = instance_double(LanternServer)
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(leader).to receive(:run_query).and_return("sync")
      expect { nx.wait_synchronization }.to hop("wait")
    end

    it "naps 30" do
      leader = instance_double(LanternServer)
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(leader).to receive(:run_query).and_return("unknown")
      expect { nx.wait_synchronization }.to nap(30)
    end
  end

  describe "#wait_recovery_completion" do
    it "hop to wait if recovery finished" do
      expect(lantern_server).to receive(:run_query).and_return("t", "paused", "")
      expect(lantern_server).to receive(:timeline_id=)
      expect(lantern_server).to receive(:timeline_access=).with("push")
      expect(lantern_server).to receive(:save_changes)
      expect(lantern_server).to receive(:update_walg_creds)
      expect(Prog::Lantern::LanternTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"))
      expect { nx.wait_recovery_completion }.to hop("wait")
    end

    it "hop to wait if not in recovery" do
      expect(lantern_server).to receive(:run_query).and_return("f")
      expect(lantern_server).to receive(:timeline_id=)
      expect(lantern_server).to receive(:timeline_access=).with("push")
      expect(lantern_server).to receive(:save_changes)
      expect(lantern_server).to receive(:update_walg_creds)
      expect(Prog::Lantern::LanternTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"))
      expect { nx.wait_recovery_completion }.to hop("wait")
    end

    it "nap 5" do
      expect(lantern_server).to receive(:run_query).and_return("t", "unk")
      expect { nx.wait_recovery_completion }.to nap(5)
    end
  end

  describe "#wait_db_available" do
    it "hops to init_sql after initial provisioning" do
      expect(nx).to receive(:available?).and_return(true)
      expect(lantern_server).to receive(:primary?).and_return(true)
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(nx).to receive(:decr_initial_provisioning)
      expect { nx.wait_db_available }.to hop("init_sql")
    end

    it "hops to wait_catch_up after initial provisioning" do
      expect(nx).to receive(:available?).and_return(true)
      expect(lantern_server).to receive(:standby?).and_return(true)
      expect(lantern_server).to receive(:primary?).and_return(false)
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(nx).to receive(:decr_initial_provisioning)
      expect { nx.wait_db_available }.to hop("wait_catch_up")
    end

    it "hops to wait_recovery_completion after initial provisioning" do
      expect(nx).to receive(:available?).and_return(true)
      expect(lantern_server).to receive(:primary?).and_return(false)
      expect(lantern_server).to receive(:standby?).and_return(false)
      expect(nx).to receive(:when_initial_provisioning_set?).and_yield
      expect(nx).to receive(:decr_initial_provisioning)
      expect { nx.wait_db_available }.to hop("wait_recovery_completion")
    end

    it "updates memory limits" do
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:when_update_memory_limits_set?).and_yield
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/update_memory_limits")
      expect(nx).to receive(:decr_update_memory_limits)
      expect { nx.wait_db_available }.to hop("wait")
    end

    it "hops to wait" do
      expect(nx).to receive(:available?).and_return(true)
      expect { nx.wait_db_available }.to hop("wait")
    end

    it "naps 10" do
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait_db_available }.to nap(10)
    end
  end

  describe "#update_lantern_extension" do
    it "updates lantern extension and naps" do
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.0").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_lantern").and_return("NotStarted")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/update_lantern' update_lantern", stdin: JSON.generate({
        version: lantern_server.lantern_version
      }))
      expect { nx.update_lantern_extension }.to nap(10)
    end

    it "naps if in progress" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_lantern").and_return("InProgress")
      expect { nx.update_lantern_extension }.to nap(10)
    end

    it "updates lantern extension and hops to wait_db_available" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_lantern").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_lantern")
      expect(nx).to receive(:decr_update_lantern_extension)
      expect { nx.update_lantern_extension }.to hop("wait_db_available")
    end

    it "updates lantern extension and fails" do
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.0").at_least(:once)
      expect(lantern_server).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_lantern").and_return("Failed")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_lantern")
      expect(nx).to receive(:decr_update_lantern_extension)
      expect(Prog::PageNexus).to receive(:assemble).with("Lantern v0.2.0 update failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternUpdateFailed", lantern_server.lantern_version)
      expect { nx.update_lantern_extension }.to hop("wait_db_available")
    end
  end

  describe "#update_extras_extension" do
    it "updates lantern extras extension and naps" do
      expect(lantern_server).to receive(:extras_version).and_return("0.2.0").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_extras").and_return("NotStarted")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/update_extras' update_lantern", stdin: JSON.generate({
        version: lantern_server.extras_version
      }))
      expect { nx.update_extras_extension }.to nap(10)
    end

    it "naps if in progress" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_extras").and_return("InProgress")
      expect { nx.update_extras_extension }.to nap(10)
    end

    it "updates lantern extras extension and hops to wait_db_available" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_extras").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_extras")
      expect(nx).to receive(:decr_update_extras_extension)
      expect { nx.update_extras_extension }.to hop("wait_db_available")
    end

    it "updates lantern extras extension and fails" do
      expect(lantern_server).to receive(:extras_version).and_return("0.2.0").at_least(:once)
      expect(lantern_server).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_extras").and_return("Failed")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_extras")
      expect(nx).to receive(:decr_update_extras_extension)
      expect(Prog::PageNexus).to receive(:assemble).with("Lantern Extras v0.2.0 update failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternUpdateFailed", lantern_server.extras_version)
      expect { nx.update_extras_extension }.to hop("wait_db_available")
    end
  end

  describe "#update_image" do
    it "updates image and naps" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds").at_least(:once)
      expect(lantern_server).to receive(:container_image).and_return("test-image").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_docker_image").and_return("NotStarted")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/update_docker_image' update_docker_image", stdin: JSON.generate({
        gcp_creds_gcr_b64: Config.gcp_creds_gcr_b64,
        container_image: lantern_server.container_image
      }))
      expect { nx.update_image }.to nap(10)
    end

    it "naps if in progress" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_docker_image").and_return("InProgress")
      expect { nx.update_image }.to nap(10)
    end

    it "updates image and hops to wait_db_available" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_docker_image").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_docker_image")
      expect(nx).to receive(:decr_update_image)
      expect { nx.update_image }.to hop("wait_db_available")
    end

    it "updates image and fails" do
      expect(lantern_server).to receive(:container_image).and_return("test-image").at_least(:once)
      expect(lantern_server).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_docker_image").and_return("Failed")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_docker_image")
      expect(nx).to receive(:decr_update_image)
      expect(Prog::PageNexus).to receive(:assemble).with("Lantern Image test-image update failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternUpdateFailed", lantern_server.container_image)
      expect { nx.update_image }.to hop("wait_db_available")
    end
  end

  describe "#add_domain" do
    it "fails to add domain" do
      expect(lantern_server.vm.sshable).to receive(:host).and_return("1.1.1.1")
      cf_client = instance_double(Dns::Cloudflare)
      expect(Dns::Cloudflare).to receive(:new).and_return(cf_client)
      expect(cf_client).to receive(:upsert_dns_record).and_raise
      allow(lantern_server).to receive(:update).with(domain: nil)
      expect { nx.add_domain }.to hop("wait")
    end

    it "adds domain and setup ssl" do
      expect(lantern_server.vm.sshable).to receive(:host).and_return("1.1.1.1")
      cf_client = instance_double(Dns::Cloudflare)
      expect(Dns::Cloudflare).to receive(:new).and_return(cf_client)
      expect(lantern_server).to receive(:domain).and_return("test.lantern.dev")
      expect(cf_client).to receive(:upsert_dns_record).with("test.lantern.dev", "1.1.1.1")
      expect { nx.add_domain }.to hop("setup_ssl")
    end
  end

  describe "#destroy_domain" do
    it "destroys domain" do
      cf_client = instance_double(Dns::Cloudflare)
      expect(Dns::Cloudflare).to receive(:new).and_return(cf_client)
      expect(lantern_server).to receive(:domain).and_return("example.com")
      expect(cf_client).to receive(:delete_dns_record).with("example.com")
      nx.destroy_domain
    end
  end

  describe "#setup_ssl" do
    it "setups ssl" do
      expect(lantern_server).to receive(:domain).and_return("example.com")
      expect(Config).to receive(:cf_token).and_return("test_cf_token")
      expect(Config).to receive(:cf_zone_id).and_return("test_zone_id")
      expect(Config).to receive(:lantern_dns_email).and_return("test@example.com")
      expect(lantern_server.vm.sshable).to receive(:cmd) do |cmd, stdin: ""|
        data = JSON.parse(stdin)
        expect(data["dns_token"]).to eq("test_cf_token")
        expect(data["dns_zone_id"]).to eq("test_zone_id")
        expect(data["dns_email"]).to eq("test@example.com")
        expect(data["domain"]).to eq("example.com")
      end

      expect { nx.setup_ssl }.to hop("wait_db_available")
    end
  end

  describe "#update_user_password" do
    it "does not update user password if user is postgres" do
      expect(lantern_server.resource).to receive(:db_user).and_return("postgres")
      expect { nx.update_user_password }.to hop("wait")
    end

    it "updates user password" do
      expect(lantern_server.resource).to receive(:db_user).and_return("lantern").exactly(3).times
      expect(lantern_server.resource).to receive(:db_user_password).and_return("pwd")
      expect(lantern_server).to receive(:run_query).with(/log_statement = 'none'.*\n.*SCRAM-SHA-256/)
      expect { nx.update_user_password }.to hop("wait")
    end
  end

  describe "#wait" do
    it "hops to update_user_password" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_user_password
      expect { nx.wait }.to hop("update_user_password")
    end

    it "hops to restart_server" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_restart_server
      expect { nx.wait }.to hop("restart_server")
    end

    it "hops to start_server" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_start_server
      expect { nx.wait }.to hop("start_server")
    end

    it "hops to stop_server" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_stop_server
      expect { nx.wait }.to hop("stop_server")
    end

    it "hops to add_domain" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_add_domain
      expect { nx.wait }.to hop("add_domain")
    end

    it "hops to update_rhizome" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_rhizome
      expect { nx.wait }.to hop("update_rhizome")
    end

    it "hops to destroy" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to update_storage_size" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_storage_size
      expect { nx.wait }.to hop("update_storage_size")
    end

    it "hops to update_vm_size" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      nx.incr_update_vm_size
      expect { nx.wait }.to hop("update_vm_size")
    end

    it "hops to wait_db_available" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "updating"))
      expect { nx.wait }.to hop("wait_db_available")
    end

    it "naps 30" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "destroys lantern_server and vm" do
      expect(lantern_server.vm).to receive(:incr_destroy).at_least(:once)
      expect(lantern_server.timeline).to receive(:incr_destroy).at_least(:once)
      expect(lantern_server).to receive(:domain).and_return(nil)
      expect(lantern_server).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "lantern server was deleted"})
    end

    it "destroys lantern_server, vm and domain" do
      expect(lantern_server.vm).to receive(:incr_destroy).at_least(:once)
      expect(lantern_server.timeline).to receive(:incr_destroy).at_least(:once)
      expect(lantern_server).to receive(:domain).and_return("example.com")
      expect(nx).to receive(:destroy_domain)
      expect(lantern_server).to receive(:destroy)
      expect { nx.destroy }.to exit({"msg" => "lantern server was deleted"})
    end
  end

  describe "#update_memory_limits" do
    it "updates memory limits" do
      expect(nx).to receive(:when_update_memory_limits_set?).and_yield
      expect(lantern_server).to receive(:run_query)
      expect(lantern_server.vm.sshable).to receive(:invalidate_cache_entry)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/update_memory_limits")
      expect { nx.wait_db_available }.to hop("wait")
    end
  end

  describe "#available" do
    it "marks as available" do
      expect(lantern_server).to receive(:run_query)
      expect(lantern_server.vm.sshable).to receive(:invalidate_cache_entry)
      expect(nx.available?).to be(true)
    end

    it "does not mark as unavailable if redo in progress" do
      expect(lantern_server).to receive(:run_query).and_raise "err"
      expect(lantern_server.vm.sshable).to receive(:invalidate_cache_entry)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/logs --tail 5").and_return("redo in progress")
      expect(nx.available?).to be(true)
    end

    it "marks unavailable if cmd fails" do
      expect(lantern_server).to receive(:run_query).and_raise "err"
      expect(lantern_server.vm.sshable).to receive(:invalidate_cache_entry)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/logs --tail 5").and_raise
      expect(nx.available?).to be(false)
    end

    it "marks unavailable if cmd returns other logs" do
      expect(lantern_server).to receive(:run_query).and_raise "err"
      expect(lantern_server.vm.sshable).to receive(:invalidate_cache_entry)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/logs --tail 5").and_return("logs")
      expect(nx.available?).to be(false)
    end
  end

  describe "#start,stop,restart" do
    it "starts vm and hop to wait_db_available" do
      expect(nx).to receive(:decr_start_server)
      expect(lantern_server.vm).to receive(:incr_start_vm)
      expect { nx.start_server }.to hop("wait_db_available")
    end

    it "stops vm and hop to wait" do
      expect(nx).to receive(:decr_stop_server)
      expect(lantern_server.vm).to receive(:incr_stop_vm)
      expect { nx.stop_server }.to hop("wait")
    end

    it "restarts vm and hop to wait" do
      expect(nx).to receive(:decr_restart_server)
      expect(nx).to receive(:incr_stop_server)
      expect(nx).to receive(:incr_start_server)
      expect { nx.restart_server }.to hop("wait")
    end
  end

  describe "#update_storage_size" do
    it "calls update_storage_size on vm" do
      expect(lantern_server.vm).to receive(:incr_update_storage)
      expect { nx.update_storage_size }.to hop("wait")
    end
  end

  describe "#update_vm_size" do
    it "calls update_vm_size on vm" do
      expect(lantern_server.vm).to receive(:incr_update_size)
      expect { nx.update_vm_size }.to hop("wait")
    end
  end
end
