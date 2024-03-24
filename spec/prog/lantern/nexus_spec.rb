# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternServerNexus do
  subject(:nx) { described_class.new(Strand.create(id: "0d77964d-c416-8edb-9237-7e7dd5d6fcf8", prog: "Postgres::LanternServerNexus", label: "start")) }

  describe ".assemble" do
    it "creates lantern server and vm with sshable" do
      postgres_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }
      expect(Config).to receive(:postgres_service_project_id).and_return(postgres_project.id).at_least(:once)

      st = described_class.assemble(
        lantern_version: "0.2.0",
        extras_version: "0.1.3",
        minor_version: "2",
        org_id: 0,
        instance_id: "instance-test",
        instance_type: "writer",
        db_name: "testdb",
        db_user: "test"
      )
      lantern_server = LanternServer[st.id]
      expect(lantern_server).not_to be_nil
      expect(lantern_server.vm).not_to be_nil
      expect(lantern_server.vm.sshable).not_to be_nil

      expect(lantern_server.lantern_version).to_be("0.2.0")
    end
  end
  #
  # describe "#start" do
  #   it "naps if vm not ready" do
  #     expect(postgres_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "prep"))
  #     expect { nx.start }.to nap(5)
  #   end
  #
  #   it "update sshable host and hops" do
  #     expect(postgres_server.vm).to receive(:strand).and_return(instance_double(Strand, label: "wait"))
  #     expect(postgres_server).to receive(:incr_initial_provisioning)
  #     expect { nx.start }.to hop("bootstrap_rhizome")
  #   end
  # end
  #
  # describe "#bootstrap_rhizome" do
  #   it "buds a bootstrap rhizome process" do
  #     expect(nx).to receive(:bud).with(Prog::BootstrapRhizome, {"target_folder" => "postgres", "subject_id" => postgres_server.vm.id, "user" => "ubi"})
  #     expect { nx.bootstrap_rhizome }.to hop("wait_bootstrap_rhizome")
  #   end
  # end
  #
  # describe "#wait_bootstrap_rhizome" do
  #   before { expect(nx).to receive(:reap) }
  #
  #   it "hops to mount_data_disk if there are no sub-programs running" do
  #     expect(nx).to receive(:leaf?).and_return true
  #
  #     expect { nx.wait_bootstrap_rhizome }.to hop("mount_data_disk")
  #   end
  #
  #   it "donates if there are sub-programs running" do
  #     expect(nx).to receive(:leaf?).and_return false
  #     expect(nx).to receive(:donate).and_call_original
  #
  #     expect { nx.wait_bootstrap_rhizome }.to nap(0)
  #   end
  # end
end
