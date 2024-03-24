# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe Prog::Lantern::LanternServerNexus do
  subject(:nx) { described_class.new(Strand.create(id: "6ae7e513-c34a-8039-a72a-7be45b53f2a0", prog: "Lantern::LanternServerNexus", label: "start")) }

  let(:sshable) { instance_double(Sshable) }

  let(:lantern_server) {
    instance_double(
      LanternServer,
      ubid: "6ae7e513-c34a-8039-a72a-7be45b53f2a0",
      gcp_vm: instance_double(
        GcpVm,
        id: "104b0033-b3f6-8214-ae27-0cd3cef18ce4",
        sshable: sshable
      )
    )
  }

  before do
    allow(nx).to receive(:lantern_server).and_return(lantern_server)
  end

  describe ".assemble" do
    it "creates lantern server and vm with sshable" do
      postgres_project = Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) }

      st = described_class.assemble(
        project_id: postgres_project.id,
        lantern_version: "0.2.0",
        extras_version: "0.1.3",
        minor_version: "2",
        org_id: 0,
        instance_id: "instance-test",
        instance_type: "writer",
        db_name: "testdb",
        target_vm_size: "standard-2",
        db_user: "test"
      )
      lantern_server = LanternServer[st.id]
      expect(lantern_server).not_to be_nil
      expect(lantern_server.gcp_vm).not_to be_nil
      expect(lantern_server.gcp_vm.sshable).not_to be_nil

      expect(lantern_server.lantern_version).to eq("0.2.0")
      expect(lantern_server.extras_version).to eq("0.1.3")
      expect(lantern_server.minor_version).to eq("2")
      expect(lantern_server.org_id).to eq(0)
      expect(lantern_server.instance_id).to eq("instance-test")
      expect(lantern_server.instance_type).to eq("writer")
      expect(lantern_server.db_name).to eq("testdb")
      expect(lantern_server.db_user).to eq("test")
      expect(lantern_server.gcp_vm.cores).to eq(1)
    end
  end

  describe "#start" do
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
  end
end
