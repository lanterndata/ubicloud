# frozen_string_literal: true

require_relative "../../model/spec_helper"
require "netaddr"

RSpec.describe Prog::GcpVm::Nexus do
  subject(:nx) {
    described_class.new(st).tap {
      _1.instance_variable_set(:@gcp_vm, gcp_vm)
    }
  }

  let(:st) { Strand.new }
  let(:gcp_vm) {
    vm = GcpVm.new(family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "us-central1", storage_size_gib: 50).tap {
      _1.id = "2464de61-7501-8374-9ab0-416caebe31da"
    }
    vm
  }
  let(:prj) { Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) } }

  describe ".assemble" do
    it "fails if there is no project" do
      expect {
        described_class.assemble("some_ssh_key", "0a9a166c-e7e7-4447-ab29-7ea442b5bb0e")
      }.to raise_error RuntimeError, "No existing project"
    end

    it "fails if project's provider and location's provider not matched" do
      expect {
        described_class.assemble("some_ssh_key", prj.id, location: "dp-istanbul-mars")
      }.to raise_error Validation::ValidationFailed, "Validation failed for following fields: provider"
    end

    it "creates arm64 vm with double core count and 3.2GB memory per core" do
      st = described_class.assemble("some_ssh_key", prj.id, size: "standard-4", arch: "arm64")
      expect(st.subject.cores).to eq(4)
      expect(st.subject.mem_gib_ratio).to eq(3.2)
      expect(st.subject.mem_gib).to eq(12)
    end
  end

  describe ".assemble_with_sshable" do
    it "calls .assemble with generated ssh key" do
      st_id = "eb3dbcb3-2c90-8b74-8fb4-d62a244d7ae5"
      expect(SshKey).to receive(:generate).and_return(instance_double(SshKey, public_key: "public", keypair: "pair"))
      expect(described_class).to receive(:assemble) do |public_key, project_id, **kwargs|
        expect(public_key).to eq("public")
        expect(project_id).to eq(prj.id)
        expect(kwargs[:name]).to be_nil
        expect(kwargs[:size]).to eq("new_size")
        expect(kwargs[:unix_user]).to eq("test_user")
      end.and_return(Strand.new(id: st_id))
      expect(Sshable).to receive(:create).with({unix_user: "test_user", host: "temp_#{st_id}", raw_private_key_1: "pair"})

      described_class.assemble_with_sshable("test_user", prj.id, size: "new_size")
    end
  end
end
