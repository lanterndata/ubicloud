# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternServerNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternServerNexus", label: "start")) }

  let(:sshable) { instance_double(Sshable) }

  let(:lantern_server) {
    instance_double(
      LanternServer,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      domain: nil,
      lantern_version: "0.2.5",
      extras_version: "0.1.5",
      resource: instance_double(LanternResource,
        org_id: 0,
        name: "test",
        db_name: "postgres",
        db_user: "postgres",
        service_account_name: "test-sa",
        gcp_creds_b64: "test-creds",
        version_upgrade: false,
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
        bucket_name: "test-bucket"
      )
    )
  }

  before do
    allow(LanternServer).to receive(:get_vm_image).and_return(Config.gcp_default_image)
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

    it "naps if resource not ready" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(lantern_server.resource).to receive(:strand).and_return(instance_double(Strand, label: "start"))
      expect { nx.start }.to nap(5)
    end

    it "hops to bootstrap_rhizome" do
      expect(lantern_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
      expect(lantern_server.resource).to receive(:strand).and_return(instance_double(Strand, label: "wait_servers"))
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
      expect(nx).to receive(:leaf?).and_return(true).at_least(:once)
      expect { nx.wait_bootstrap_rhizome }.to hop("setup_docker_stack")
    end

    it "donates if there are sub-programs running" do
      expect(nx).to receive(:leaf?).and_return(false).at_least(:once)
      expect(nx).to receive(:donate).and_call_original
      expect { nx.wait_bootstrap_rhizome }.to nap(0)
    end
  end

  describe "#setup_docker_stack" do
    before do
      allow(lantern_server.timeline).to receive(:strand).and_return(instance_double(Strand, label: "wait_leader"))
    end

    it "naps if timeline is not ready" do
      expect(lantern_server.timeline).to receive(:strand).and_return(instance_double(Strand, label: "start"))
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds")
      expect { nx.setup_docker_stack }.to nap(10)
    end

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
      expect(lantern_server).to receive(:primary?).and_return(true)
      expect(nx).to receive(:register_deadline).with(:wait, 40 * 60)
      expect { nx.setup_docker_stack }.to hop("wait_db_available")
    end

    it "hop to wait_db_available" do
      expect(Config).to receive(:gcp_creds_gcr_b64).and_return("test-creds")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check configure_lantern").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean configure_lantern")
      expect(lantern_server).to receive(:domain).and_return(nil)
      expect(lantern_server).to receive(:primary?).and_return(false)
      expect(nx).to receive(:register_deadline).with(:wait, 120 * 60)
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
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean init_sql")
      expect(lantern_server).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server).to receive(:container_image).and_return("test-image").at_least(:once)
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(Prog::PageNexus).to receive(:assemble).with("Lantern init sql failed!", [lantern_server.resource.ubid, lantern_server.ubid], "LanternInitSQLFailed", lantern_server.container_image)
      expect { nx.init_sql }.to hop("wait")
    end

    it "hops to wait_db_available" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check init_sql").and_return("Succeeded")
      expect(nx).to receive(:bud).with(described_class, {}, :prewarm_indexes)
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
      expect(lantern_server.resource).to receive(:delete_replication_slot).with(lantern_server.ubid)
      expect(leader).to receive(:run_query).and_return((1 * 1024 * 1024).to_s)
      expect { nx.wait_catch_up }.to hop("wait_synchronization")
    end

    it "hops to wait" do
      leader = instance_double(LanternServer)
      expect(lantern_server).to receive(:update).with({synchronization_status: "ready"})
      expect(lantern_server.resource).to receive(:representative_server).and_return(leader)
      expect(lantern_server.resource).to receive(:ha_type).and_return(LanternResource::HaType::ASYNC)
      expect(lantern_server.resource).to receive(:delete_replication_slot).with(lantern_server.ubid)
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
      expect(lantern_server.resource).to receive(:allow_timeline_access_to_bucket)
      expect(lantern_server).to receive(:run_query).and_return("t", "paused", "t", lantern_server.lantern_version, lantern_server.extras_version)
      expect(lantern_server).to receive(:timeline_id=)
      expect(lantern_server).to receive(:timeline_access=).with("push")
      expect(lantern_server).to receive(:save_changes)
      expect(Prog::Lantern::LanternTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"))
      expect { nx.wait_recovery_completion }.to hop("wait_timeline_available")
    end

    it "hop to wait if not in recovery" do
      expect(lantern_server.resource).to receive(:allow_timeline_access_to_bucket)
      expect(lantern_server).to receive(:run_query).and_return("f", lantern_server.lantern_version, lantern_server.extras_version)
      expect(lantern_server).to receive(:timeline_id=)
      expect(lantern_server).to receive(:timeline_access=).with("push")
      expect(lantern_server).to receive(:save_changes)
      expect(Prog::Lantern::LanternTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"))
      expect { nx.wait_recovery_completion }.to hop("wait_timeline_available")
    end

    it "do not update extension on upgrade" do
      expect(lantern_server.resource).to receive(:allow_timeline_access_to_bucket)
      expect(lantern_server).to receive(:run_query).and_return("f")
      expect(lantern_server).to receive(:timeline_id=)
      expect(lantern_server).to receive(:timeline_access=).with("push")
      expect(lantern_server).to receive(:save_changes)
      expect(lantern_server.resource).to receive(:version_upgrade).and_return(true)
      expect(Prog::Lantern::LanternTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"))
      expect { nx.wait_recovery_completion }.to hop("wait_timeline_available")
    end

    it "update extension on version mismatch" do
      expect(lantern_server.resource).to receive(:allow_timeline_access_to_bucket)
      expect(lantern_server).to receive(:run_query).and_return("t", "paused", "t", "0.2.4", "0.1.4")
      expect(lantern_server).to receive(:timeline_id=)
      expect(lantern_server).to receive(:timeline_access=).with("push")
      expect(lantern_server).to receive(:save_changes)
      expect(lantern_server).to receive(:update).with(lantern_version: "0.2.4")
      expect(lantern_server).to receive(:update).with(extras_version: "0.1.4")
      expect(nx).to receive(:incr_update_lantern_extension)
      expect(nx).to receive(:incr_update_extras_extension)
      expect(Prog::Lantern::LanternTimelineNexus).to receive(:assemble).and_return(instance_double(Strand, id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"))
      expect { nx.wait_recovery_completion }.to hop("wait_timeline_available")
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
      expect { nx.update_lantern_extension }.to hop("init_sql")
    end

    it "updates lantern extension and fails" do
      expect(lantern_server).to receive(:lantern_version).and_return("0.2.0").at_least(:once)
      expect(lantern_server).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_lantern").and_return("Failed")
      logs = {"stdout" => "", "stderr" => "oom"}
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --logs update_lantern").and_return(JSON.generate(logs))
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_lantern")
      expect(nx).to receive(:decr_update_lantern_extension)
      expect(Prog::PageNexus).to receive(:assemble_with_logs).with("Lantern v0.2.0 update failed!", [lantern_server.resource.ubid, lantern_server.ubid], logs, "critical", "LanternUpdateFailed", lantern_server.ubid)
      expect { nx.update_lantern_extension }.to hop("wait")
    end
  end

  describe "#update_extras_extension" do
    it "updates lantern extras extension and naps" do
      expect(lantern_server).to receive(:extras_version).and_return("0.2.0").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_extras").and_return("NotStarted")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/update_extras' update_extras", stdin: JSON.generate({
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
      expect { nx.update_extras_extension }.to hop("init_sql")
    end

    it "updates lantern extras extension and fails" do
      expect(lantern_server).to receive(:extras_version).and_return("0.2.0").at_least(:once)
      expect(lantern_server).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_extras").and_return("Failed")
      logs = {"stdout" => "", "stderr" => "oom"}
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --logs update_extras").and_return(JSON.generate(logs))
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_extras")
      expect(nx).to receive(:decr_update_extras_extension)
      expect(Prog::PageNexus).to receive(:assemble_with_logs).with("Lantern Extras v0.2.0 update failed!", [lantern_server.resource.ubid, lantern_server.ubid], logs, "critical", "LanternExtrasUpdateFailed", lantern_server.ubid)
      expect { nx.update_extras_extension }.to hop("wait")
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
      expect { nx.update_image }.to hop("update_lantern_extension")
    end

    it "updates image and fails" do
      expect(lantern_server).to receive(:container_image).and_return("test-image").at_least(:once)
      expect(lantern_server).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check update_docker_image").and_return("Failed")
      logs = {"stdout" => "", "stderr" => "oom"}
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --logs update_docker_image").and_return(JSON.generate(logs))
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean update_docker_image")
      expect(nx).to receive(:decr_update_image)
      expect(Prog::PageNexus).to receive(:assemble_with_logs).with("Lantern Image test-image update failed!", [lantern_server.resource.ubid, lantern_server.ubid], logs, "critical", "LanternImageUpdateFailed", lantern_server.ubid)
      expect { nx.update_image }.to hop("wait")
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
    it "calls setup ssl and naps" do
      expect(lantern_server).to receive(:domain).and_return("example.com").at_least(:once)
      expect(Config).to receive(:cf_token).and_return("test_cf_token").at_least(:once)
      expect(Config).to receive(:cf_zone_id).and_return("test_zone_id").at_least(:once)
      expect(Config).to receive(:lantern_dns_email).and_return("test@example.com").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check setup_ssl").and_return("NotStarted")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/setup_ssl' setup_ssl", stdin: JSON.generate({
        dns_token: Config.cf_token,
        dns_zone_id: Config.cf_zone_id,
        dns_email: Config.lantern_dns_email,
        domain: lantern_server.domain
      }))
      expect { nx.setup_ssl }.to nap(10)
    end

    it "naps if in progress" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check setup_ssl").and_return("InProgress")
      expect { nx.setup_ssl }.to nap(10)
    end

    it "sets up ssl and hops to wait_db_available" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check setup_ssl").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean setup_ssl")
      expect { nx.setup_ssl }.to hop("wait_db_available")
    end

    it "setup ssl and fails" do
      expect(lantern_server.resource).to receive(:ubid).and_return("test-ubid").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check setup_ssl").and_return("Failed")
      logs = {"stdout" => "", "stderr" => "oom"}
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --logs setup_ssl").and_return(JSON.generate(logs))
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean setup_ssl")
      expect(Prog::PageNexus).to receive(:assemble_with_logs).with("Lantern SSL Setup Failed for test", [lantern_server.resource.ubid, lantern_server.ubid], logs, "error", "LanternSSLSetupFailed", lantern_server.ubid)
      expect { nx.setup_ssl }.to hop("wait")
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
      nx.incr_update_user_password
      expect { nx.wait }.to hop("update_user_password")
    end

    it "hops to restart_server" do
      nx.incr_restart_server
      expect { nx.wait }.to hop("restart_server")
    end

    it "hops to start_server" do
      nx.incr_start_server
      expect { nx.wait }.to hop("start_server")
    end

    it "hops to stop_server" do
      nx.incr_stop_server
      expect { nx.wait }.to hop("stop_server")
    end

    it "hops to add_domain" do
      nx.incr_add_domain
      expect { nx.wait }.to hop("add_domain")
    end

    it "hops to update_rhizome" do
      nx.incr_update_rhizome
      expect { nx.wait }.to hop("update_rhizome")
    end

    it "hops to update_rhizome if update lantern set" do
      nx.incr_update_lantern_extension
      expect { nx.wait }.to hop("update_rhizome")
    end

    it "hops to update_rhizome if update extras set" do
      nx.incr_update_extras_extension
      expect { nx.wait }.to hop("update_rhizome")
    end

    it "hops to update_rhizome if update image set" do
      nx.incr_update_image
      expect { nx.wait }.to hop("update_rhizome")
    end

    it "hops to destroy" do
      nx.incr_destroy
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to update_storage_size" do
      nx.incr_update_storage_size
      expect { nx.wait }.to hop("update_storage_size")
    end

    it "hops to update_vm_size" do
      nx.incr_update_vm_size
      expect { nx.wait }.to hop("update_vm_size")
    end

    it "hops to unavailable" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(false)
      expect { nx.wait }.to hop("unavailable")
    end

    it "hops to take_over" do
      nx.incr_take_over
      expect { nx.wait }.to hop("take_over")
    end

    it "hops to container_stopped" do
      nx.incr_container_stopped
      expect { nx.wait }.to hop("container_stopped")
    end

    it "decrements checkup" do
      nx.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:decr_checkup)
      expect { nx.wait }.to nap(30)
    end

    it "naps 30" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#destroy" do
    it "destroys lantern_server and vm" do
      expect(lantern_server.vm).to receive(:incr_destroy).at_least(:once)
      expect(lantern_server).to receive(:primary?).and_return(false)
      expect(lantern_server).to receive(:domain).and_return(nil)
      expect(lantern_server).to receive(:destroy)
      expect(lantern_server.resource).to receive(:delete_replication_slot).with(lantern_server.ubid)
      expect { nx.destroy }.to exit({"msg" => "lantern server was deleted"})
    end

    it "destroys lantern_server, vm and domain" do
      expect(lantern_server.vm).to receive(:incr_destroy).at_least(:once)
      expect(lantern_server).to receive(:primary?).and_return(true)
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

  describe "#unavailable" do
    it "naps if restarting" do
      expect(nx).to receive(:reap)
      expect(nx.strand).to receive(:children).and_return([instance_double(Strand, prog: "Lantern::LanternServerNexus", label: "restart")])
      expect { nx.unavailable }.to nap(5)
    end

    it "hops to wait if available" do
      expect(nx).to receive(:reap)
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:decr_checkup)
      expect { nx.unavailable }.to hop("wait")
    end

    it "hops to wait if available and resolves page" do
      expect(nx).to receive(:reap)
      expect(nx).to receive(:available?).and_return(true)
      expect(nx).to receive(:decr_checkup)
      page = instance_double(Page)
      expect(Page).to receive(:from_tag_parts).with("DBUnavailable", lantern_server.id).and_return(page)
      expect(page).to receive(:incr_resolve)
      expect { nx.unavailable }.to hop("wait")
    end

    it "buds restart" do
      expect(nx).to receive(:reap)
      expect(nx).to receive(:available?).and_return(false)
      expect(nx).to receive(:bud).with(described_class, {}, :restart)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/logs --tail 10").and_return("test logs")
      expect(Prog::PageNexus).to receive(:assemble_with_logs).with("DB #{lantern_server.resource.name} is unavailable!", [lantern_server.ubid], {"stderr" => "", "stdout" => "test logs"}, "critical", "DBUnavailable", lantern_server.id)
      expect { nx.unavailable }.to nap(5)
    end

    it "naps if already alerted" do
      expect(nx).to receive(:reap)
      expect(nx).to receive(:available?).and_return(false)
      page = instance_double(Page)
      expect(Page).to receive(:from_tag_parts).with("DBUnavailable", lantern_server.id).and_return(page)
      expect { nx.unavailable }.to nap(5)
    end
  end

  describe "#restart" do
    it "restarts docker container" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("sudo lantern/bin/restart")
      expect { nx.restart }.to exit({"msg" => "lantern server is restarted"})
    end
  end

  describe "#prewarm_indexes" do
    it "naps if in progress" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check prewarm_indexes").and_return("InProgress")
      expect { nx.prewarm_indexes }.to nap(30)
    end

    it "calls prewarm if not started" do
      expect(lantern_server).to receive(:prewarm_indexes_query).and_return("test").at_least(:once)
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check prewarm_indexes").and_return("NotStarted")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer 'sudo lantern/bin/exec_all' prewarm_indexes", stdin: lantern_server.prewarm_indexes_query)
      expect { nx.prewarm_indexes }.to nap(30)
    end

    it "cleans and resolves page" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check prewarm_indexes").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean prewarm_indexes")
      page = instance_double(Page)
      expect(page).to receive(:incr_resolve).at_least(:once)
      expect(Page).to receive(:from_tag_parts).at_least(:once).and_return(page)
      expect { nx.prewarm_indexes }.to exit({"msg" => "lantern index prewarm success"})
    end

    it "cleans and exits" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check prewarm_indexes").and_return("Succeeded")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean prewarm_indexes")
      expect(Page).to receive(:from_tag_parts).at_least(:once).and_return(nil)
      expect { nx.prewarm_indexes }.to exit({"msg" => "lantern index prewarm success"})
    end

    it "fails and creates page" do
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --check prewarm_indexes").and_return("Failed")
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --logs prewarm_indexes").and_return(JSON.generate({"stdout" => "test"}))
      expect(lantern_server.vm.sshable).to receive(:cmd).with("common/bin/daemonizer --clean prewarm_indexes")
      page = instance_double(Page)
      expect(page).to receive(:incr_resolve).at_least(:once)
      expect(Page).to receive(:from_tag_parts).at_least(:once).and_return(page)
      expect(lantern_server).to receive(:ubid)
      expect(lantern_server.resource).to receive(:ubid)
      expect(Prog::PageNexus).to receive(:assemble_with_logs).at_least(:once)
      expect { nx.prewarm_indexes }.to exit({"msg" => "lantern index prewarm failed"})
    end
  end

  describe "#wait_timeline_available" do
    it "naps if timeline is not ready" do
      expect(lantern_server).to receive(:timeline).and_return(instance_double(LanternTimeline, strand: instance_double(Strand, label: "start")))
      expect { nx.wait_timeline_available }.to nap(10)
    end

    it "hops to wait_db_available" do
      expect(lantern_server).to receive(:timeline).and_return(instance_double(LanternTimeline, strand: instance_double(Strand, label: "wait_leader")))
      expect(lantern_server).to receive(:update_walg_creds)
      expect(nx).to receive(:decr_initial_provisioning)
      expect { nx.wait_timeline_available }.to hop("wait_db_available")
    end
  end

  describe "#take_over" do
    it "returns if primary" do
      expect(lantern_server).to receive(:standby?).and_return(false)
      expect { nx.take_over }.to hop("wait")
    end

    it "stop old master" do
      expect(lantern_server).to receive(:standby?).and_return(true)

      current_master = instance_double(LanternServer, domain: "db1.lantern.dev", vm: instance_double(GcpVm, sshable: instance_double(Sshable, host: "127.0.0.1"), name: "old-master", location: "us-east1", address_name: "old-addr"))
      expect(lantern_server.resource).to receive(:representative_server).and_return(current_master).at_least(:once)

      expect(current_master.vm.sshable).to receive(:cmd)
      expect(current_master).to receive(:incr_container_stopped)

      expect { nx.take_over }.to hop("swap_ip")
    end

    it "swap ips" do
      current_master = instance_double(LanternServer, domain: "db1.lantern.dev", vm: instance_double(GcpVm, sshable: instance_double(Sshable, host: "127.0.0.1"), name: "old-master", location: "us-east1", address_name: "old-addr"))
      expect(lantern_server.resource).to receive(:representative_server).and_return(current_master).at_least(:once)

      expect(lantern_server.vm).to receive(:swap_ip).with(current_master.vm)

      expect { nx.swap_ip }.to hop("wait_swap_ip")
    end

    it "waits until vm available" do
      expect(lantern_server).to receive(:run_query).with("SELECT 1").and_raise "test"
      expect { nx.wait_swap_ip }.to nap 5
    end

    it "hops to promote" do
      expect(lantern_server).to receive(:run_query).with("SELECT 1")
      expect { nx.wait_swap_ip }.to hop("promote_server")
    end

    it "promotes server" do
      current_master = instance_double(LanternServer, domain: "db1.lantern.dev", vm: instance_double(GcpVm, sshable: instance_double(Sshable, host: "127.0.0.1"), name: "old-master", location: "us-east1", address_name: "old-addr"))
      expect(lantern_server.resource).to receive(:representative_server).and_return(current_master).at_least(:once)

      expect(current_master).to receive(:update).with(domain: lantern_server.domain).at_least(:once)
      expect(lantern_server).to receive(:update).with(domain: current_master.domain).at_least(:once)

      expect(lantern_server).to receive(:run_query).with("SELECT pg_promote(true, 120);")
      expect(current_master).to receive(:change_replication_mode).with("slave", update_env: false)
      expect(lantern_server).to receive(:change_replication_mode).with("master")
      expect(nx).to receive(:incr_initial_provisioning)
      expect { nx.promote_server }.to hop("wait_db_available")
    end
  end

  describe "#container_stopped" do
    it "hops to take_over" do
      nx.incr_take_over
      expect(lantern_server.vm.sshable).to receive(:cmd)
      expect { nx.container_stopped }.to hop("take_over")
    end

    it "naps 15" do
      expect { nx.container_stopped }.to nap(15)
    end
  end
end
