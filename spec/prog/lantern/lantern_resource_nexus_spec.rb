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
      servers: [instance_double(
        LanternServer,
        vm: instance_double(
          GcpVm,
          id: "104b0033-b3f6-8214-ae27-0cd3cef18ce4"
        )
      )],
      representative_server: instance_double(
        LanternServer,
        vm: instance_double(
          GcpVm,
          id: "104b0033-b3f6-8214-ae27-0cd3cef18ce5"
        )
      )
    ).as_null_object
  }

  before do
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

    it "creates additional servers for HA" do
      expect(Prog::Lantern::LanternServerNexus).to receive(:assemble).with(hash_including(timeline_access: "push"))
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
    it "naps if vm not ready" do
      expect(lantern_resource.representative_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
      expect { nx.start }.to nap(5)
    end

    it "registers deadline and hops" do
      expect(lantern_resource.representative_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
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

    it "hops if server is ready" do
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
  end

  describe "#destroy" do
    it "triggers server deletion and waits until it is deleted" do
      expect(lantern_resource.servers).to all(receive(:incr_destroy))
      expect { nx.destroy }.to nap(5)

      expect(lantern_resource).to receive(:servers).and_return([])
      expect(lantern_resource).to receive(:dissociate_with_project)
      expect(lantern_resource).to receive(:destroy)

      expect { nx.destroy }.to exit({"msg" => "lantern resource is deleted"})
    end
  end
end
