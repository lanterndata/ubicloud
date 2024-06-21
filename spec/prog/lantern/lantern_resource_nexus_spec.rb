# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternResourceNexus do
  subject(:nx) { described_class.new(Strand.new(id: "8148ebdf-66b8-8ed0-9c2f-8cfe93f5aa77")) }

  let(:lantern_resource) {
    instance_double(
      LanternResource,
      ubid: "1rnjbsrja7ka4nk7ptcg03szg2",
      location: "us-central1",
      org_id: 0,
      parent: nil,
      logical_replication: false,
      servers: [instance_double(
        LanternServer,
        vm: instance_double(
          GcpVm,
          id: "104b0033-b3f6-8214-ae27-0cd3cef18ce4"
        )
      )],
      representative_server: instance_double(
        LanternServer,
        lantern_version: Config.lantern_default_version,
        extras_version: Config.lantern_extras_default_version,
        minor_version: Config.lantern_minor_default_version,
        target_vm_size: "n1-standard-2",
        target_storage_size_gib: 64,

        vm: instance_double(
          GcpVm,
          id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"
        )
      )
    ).as_null_object
  }

  before do
    allow(LanternServer).to receive(:get_vm_image).and_return(Config.gcp_default_image)
    allow(nx).to receive(:lantern_resource).and_return(lantern_resource)
  end

  describe ".assemble" do
    let(:lantern_project) { Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) } }

    it "validates input" do
      expect {
        described_class.assemble(project_id: "26820e05-562a-4e25-a51b-de5f78bd00af", location: "us-central1", name: "pg-name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100)
      }.to raise_error RuntimeError, "No existing project"

      expect {
        described_class.assemble(project_id: lantern_project.id, location: "us-central-xxx", name: "pg-name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: provider"

      expect {
        described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg/server/name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: name"

      expect {
        described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name", target_vm_size: "standard-128", target_storage_size_gib: 100)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: size"

      expect {
        described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, parent_id: "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0b")
      }.to raise_error RuntimeError, "No existing parent"

      expect {
        timeline = instance_double(LanternTimeline)
        parent = instance_double(LanternResource, id: "103b0033-b3f6-8214-ae27-0cd3cef18ce3")
        expect(parent).to receive(:timeline).and_return(timeline).at_least(:once)
        expect(parent.timeline).to receive(:refresh_earliest_backup_completion_time).and_return(Time.now)
        expect(parent.timeline).to receive(:earliest_restore_time).and_return(Time.now)
        expect(parent.timeline).to receive(:latest_restore_time).and_return(Time.now)
        expect(LanternResource).to receive(:[]).with(parent.id).and_return(parent)
        described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, parent_id: parent.id, restore_target: Time.now)
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: restore_target"
    end

    it "generates user password" do
      st = described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "2", db_user: "test", db_user_password: nil).subject
      resource = LanternResource[st.id]
      expect(resource.db_user_password).not_to be_nil
    end

    it "passes timeline of parent resource if parent is passed" do
      parent = described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "2").subject
      restore_target = Time.now
      parent.timeline.update(earliest_backup_completed_at: restore_target - 10 * 60)
      expect(parent.timeline).to receive(:refresh_earliest_backup_completion_time).and_return(restore_target - 10 * 60)
      expect(LanternResource).to receive(:[]).with(parent.id).and_return(parent)
      expect(Prog::Lantern::LanternServerNexus).to receive(:assemble).with(hash_including(timeline_id: parent.timeline.id, timeline_access: "fetch", domain: nil, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "2"))

      described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name-2", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, parent_id: parent.id, restore_target: restore_target, lantern_version: "0.2.2", extras_version: "0.1.4", minor_version: "2")
    end

    it "uses different version if version_upgrade is specified on fork" do
      parent = described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, lantern_version: "0.3.2", extras_version: "0.1.4", minor_version: "2").subject
      restore_target = Time.now
      parent.timeline.update(earliest_backup_completed_at: restore_target - 10 * 60)
      expect(parent.timeline).to receive(:refresh_earliest_backup_completion_time).and_return(restore_target - 10 * 60)
      expect(LanternResource).to receive(:[]).with(parent.id).and_return(parent)
      expect(Prog::Lantern::LanternServerNexus).to receive(:assemble).with(hash_including(timeline_id: parent.timeline.id, timeline_access: "fetch", domain: nil, lantern_version: "0.3.2", extras_version: "0.1.4", minor_version: "2"))

      described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name-2", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, parent_id: parent.id, restore_target: restore_target, lantern_version: "0.3.2", extras_version: "0.1.4", minor_version: "2", version_upgrade: true)
    end

    it "creates additional servers for HA" do
      expect(Prog::Lantern::LanternServerNexus).to receive(:assemble).with(hash_including(timeline_access: "push")).and_call_original
      expect(Prog::Lantern::LanternServerNexus).to receive(:assemble).with(hash_including(timeline_access: "fetch")).twice
      described_class.assemble(project_id: lantern_project.id, location: "us-central1", name: "pg-name-2", target_vm_size: "n1-standard-2", target_storage_size_gib: 100, ha_type: "sync")
    end
  end

  describe "#before_run" do
    it "hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.before_run }.to hop("destroy")
    end

    it "does not hop to destroy if already in the destroy state" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect(nx.strand).to receive(:label).and_return("destroy")
      expect { nx.before_run }.not_to hop("destroy")
    end
  end

  describe "#start" do
    it "sets up gcp service account and allows bucket usage" do
      expect(lantern_resource).to receive(:setup_service_account)
      expect(lantern_resource).to receive(:create_logging_table)
      expect(lantern_resource).to receive(:parent_id).and_return("test-parent")
      expect(lantern_resource).not_to receive(:allow_timeline_access_to_bucket)
      expect(nx).to receive(:register_deadline)
      expect { nx.start }.to hop("wait_servers")
    end

    it "sets up gcp service account" do
      expect(lantern_resource).to receive(:setup_service_account)
      expect(lantern_resource).to receive(:create_logging_table)
      expect(lantern_resource).to receive(:parent_id).and_return(nil)
      expect(lantern_resource).to receive(:allow_timeline_access_to_bucket)
      expect(nx).to receive(:register_deadline)
      expect { nx.start }.to hop("wait_servers")
    end

    # it "buds trigger_pg_current_xact_id_on_parent if it has parent" do
    #   expect(lantern_resource.representative_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
    #   expect(nx).to receive(:register_deadline)
    # expect(lantern_resource).to receive(:parent).and_return(instance_double(LanternResource))
    # expect(nx).to receive(:bud).with(described_class, {}, :trigger_pg_current_xact_id_on_parent)
    # expect { nx.start }.to hop("wait_servers")
    # end
  end

  # describe "#wait_trigger_pg_current_xact_id_on_parent" do
  #   it "naps" do
  #     expect(nx).to receive(:leaf?).and_return(false)
  #     expect { nx.wait_trigger_pg_current_xact_id_on_parent }.to nap(5)
  #   end
  #
  #   it "hops to wait_servers" do
  #     expect(nx).to receive(:leaf?).and_return(true)
  #     expect { nx.wait_trigger_pg_current_xact_id_on_parent }.to hop("wait_servers")
  #   end
  # end

  # describe "#trigger_pg_current_xact_id_on_parent" do
  #   it "triggers pg_current_xact_id and pops" do
  #     representative_server = instance_double(LanternServer)
  #     expect(representative_server).to receive(:run_query).with("SELECT pg_current_xact_id()")
  #     expect(lantern_resource).to receive(:parent).and_return(instance_double(LanternResource, representative_server: representative_server))
  #
  #     expect { nx.trigger_pg_current_xact_id_on_parent }.to exit({"msg" => "triggered pg_current_xact_id"})
  #   end
  # end

  describe "#wait_servers" do
    it "naps if server not ready" do
      expect(lantern_resource.servers).to all(receive(:strand).and_return(instance_double(Strand, label: "start")))

      expect { nx.wait_servers }.to nap(5)
    end

    it "hops to enable_logical_replication" do
      expect(lantern_resource.servers).to all(receive(:strand).and_return(instance_double(Strand, label: "wait")))
      expect(lantern_resource).to receive(:logical_replication).and_return(true)
      expect { nx.wait_servers }.to hop("enable_logical_replication")
    end

    it "hops to if server is ready" do
      expect(lantern_resource.servers).to all(receive(:strand).and_return(instance_double(Strand, label: "wait")))
      expect { nx.wait_servers }.to hop("wait")
    end
  end

  describe "#wait" do
    it "creates missing standbys" do
      expect(lantern_resource).to receive(:required_standby_count).and_return(1)
      expect(Prog::Lantern::LanternServerNexus).to receive(:assemble)
      expect { nx.wait }.to nap(30)
    end

    it "updates display_state" do
      expect(lantern_resource).to receive(:required_standby_count).and_return(0)
      expect(lantern_resource).to receive(:display_state).and_return("failed")
      expect(lantern_resource).to receive(:servers).and_return([instance_double(LanternServer, strand: instance_double(Strand, label: "wait"))]).at_least(:once)
      expect(lantern_resource).to receive(:update).with(display_state: nil)
      expect { nx.wait }.to nap(30)
    end

    it "does not updates display_state" do
      expect(lantern_resource).to receive(:required_standby_count).and_return(0)
      expect(lantern_resource).to receive(:display_state).and_return("failed")
      expect(lantern_resource).to receive(:servers).and_return([instance_double(LanternServer, strand: instance_double(Strand, label: "unavailable"))]).at_least(:once)
      expect { nx.wait }.to nap(30)
    end

    it "naps if no parent on swap_leaders" do
      expect(lantern_resource).to receive(:required_standby_count).and_return(0)
      expect(lantern_resource).to receive(:display_state).and_return(nil)
      expect(lantern_resource).to receive(:servers).and_return([instance_double(LanternServer, strand: instance_double(Strand, label: "wait"))]).at_least(:once)
      expect(nx).to receive(:when_swap_leaders_with_parent_set?).and_yield
      expect(lantern_resource).to receive(:parent).and_return(nil)
      expect(nx).to receive(:decr_swap_leaders_with_parent)
      expect { nx.wait }.to nap(30)
    end

    it "hops to swap_leaders" do
      expect(lantern_resource).to receive(:required_standby_count).and_return(0)
      expect(lantern_resource).to receive(:display_state).and_return(nil)
      expect(lantern_resource).to receive(:servers).and_return([instance_double(LanternServer, strand: instance_double(Strand, label: "wait"))]).at_least(:once)
      expect(nx).to receive(:when_swap_leaders_with_parent_set?).and_yield
      parent = instance_double(LanternResource)
      expect(lantern_resource).to receive(:parent).and_return(parent).at_least(:once)
      expect(parent).to receive(:update).with(display_state: "failover")
      expect(lantern_resource).to receive(:update).with(display_state: "failover")
      expect { nx.wait }.to hop("swap_leaders_with_parent")
    end
  end

  describe "#destroy" do
    it "triggers server deletion and waits until it is deleted" do
      expect(lantern_resource.servers).to all(receive(:incr_destroy))
      expect { nx.destroy }.to nap(5)

      expect(lantern_resource).to receive(:servers).and_return([])
      expect(lantern_resource).to receive(:dissociate_with_project)
      expect(lantern_resource).to receive(:destroy)
      expect(lantern_resource).to receive(:doctor).and_return(nil)
      expect(lantern_resource).to receive(:service_account_name).and_return(nil)

      expect { nx.destroy }.to exit({"msg" => "lantern resource is deleted"})
    end

    it "triggers server deletion and deletes doctor" do
      expect(lantern_resource.servers).to all(receive(:incr_destroy))
      expect { nx.destroy }.to nap(5)

      expect(lantern_resource).to receive(:servers).and_return([])
      expect(lantern_resource).to receive(:dissociate_with_project)
      expect(lantern_resource).to receive(:destroy)
      api = instance_double(Hosting::GcpApis)
      allow(Hosting::GcpApis).to receive(:new).and_return(api)
      allow(api).to receive(:remove_big_query_table).with(Config.lantern_log_dataset, lantern_resource.big_query_table)
      allow(api).to receive(:remove_service_account).with(lantern_resource.service_account_name)
      doctor = instance_double(LanternDoctor)
      expect(lantern_resource).to receive(:doctor).and_return(doctor)
      expect(doctor).to receive(:incr_destroy)

      expect { nx.destroy }.to exit({"msg" => "lantern resource is deleted"})
    end
  end

  describe "#enable_logical_replication" do
    it "enables logical replication" do
      expect(lantern_resource).to receive(:listen_ddl_log)
      expect(lantern_resource).to receive(:create_and_enable_subscription)
      expect { nx.enable_logical_replication }.to hop("wait")
    end
  end

  describe "#swap_leaders_with_parent" do
    it "swaps ips with parent leader" do
      parent = instance_double(LanternResource)
      representative_server = instance_double(LanternServer)
      vm = instance_double(GcpVm)
      expect(parent).to receive(:representative_server).and_return(representative_server)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource).to receive(:disable_logical_subscription)
      expect(representative_server).to receive(:vm).and_return(vm).at_least(:once)
      expect(vm).to receive(:swap_ip)
      expect(lantern_resource).to receive(:parent).and_return(parent).at_least(:once)
      expect(parent).to receive(:set_to_readonly)
      expect { nx.swap_leaders_with_parent }.to hop("wait_swap_ip")
    end
  end

  describe "#wait_swap_ip" do
    it "naps if error" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(representative_server).to receive(:run_query).and_raise "test"
      expect { nx.wait_swap_ip }.to nap(5)
    end

    it "hops if ready" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(representative_server).to receive(:run_query)
      expect { nx.wait_swap_ip }.to hop("update_hosts")
    end
  end

  describe "#update_hosts" do
    it "updates the domains of the current and new master, updates display states, and removes fork association" do
      parent = instance_double(LanternResource)
      current_master = instance_double(LanternServer, domain: "current-master-domain.com")
      new_master = instance_double(LanternServer, domain: "new-master-domain.com")
      timeline = instance_double(LanternTimeline)

      expect(lantern_resource).to receive(:parent).and_return(parent).at_least(:once)
      expect(parent).to receive(:representative_server).and_return(current_master).at_least(:once)
      expect(lantern_resource).to receive(:representative_server).and_return(new_master).at_least(:once)
      expect(new_master).to receive(:update).with(domain: "current-master-domain.com")
      expect(current_master).to receive(:update).with(domain: "new-master-domain.com")

      expect(lantern_resource).to receive(:update).with(display_state: nil)
      expect(parent).to receive(:update).with(display_state: nil)

      expect(lantern_resource).to receive(:update).with(parent_id: nil)
      expect(lantern_resource).to receive(:timeline).and_return(timeline)
      expect(timeline).to receive(:update).with(parent_id: nil)

      expect { nx.update_hosts }.to hop("wait")
    end
  end
end
