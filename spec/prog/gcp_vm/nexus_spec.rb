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
    vm = GcpVm.new_with_id(family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "us-central1", storage_size_gib: 50)
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
      st = described_class.assemble("some_ssh_key", prj.id, size: "standard-4", arch: "arm64", domain: "test-domain")
      expect(st.subject.cores).to eq(4)
      expect(st.subject.mem_gib_ratio).to eq(3.2)
      expect(st.subject.mem_gib).to eq(12)
      expect(st.subject.domain).to eq("test-domain")
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

  describe "#create_vm" do
    before do
      expect(Config).to receive(:gcp_project_id).and_return("test-project")
    end
    it "Hops to wait_create_vm on start" do
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      expect { nx.start }.to hop("wait_create_vm")
    end

    it "Naps 10 seconds if vm is not running" do
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "PROVISIONING"}), headers: {"Content-Type" => "application/json"})
      expect { nx.wait_create_vm }.to nap(10)
    end

    it "hops to create_static_ipv4" do
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "RUNNING"}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      expect { nx.wait_create_vm }.to hop("wait_ipv4")
    end

    it "hops to wait_sshable after assigning ipv4" do
      sshable = instance_double(Sshable)
      expect(gcp_vm).to receive(:sshable).and_return(sshable)
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "RUNNING"}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses/dummy-vm-addr").to_return(status: 200, body: JSON.dump({status: "RESERVED", address: "1.1.1.1"}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/deleteAccessConfig?accessConfig=External%20NAT&networkInterface=nic0").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm/addAccessConfig?networkInterface=nic0").with(body: JSON.dump({name: "External NAT", natIP: "1.1.1.1", networkTier: "PREMIUM", type: "ONE_TO_ONE_NAT"})).to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      expect(gcp_vm).to receive(:update).with({:has_static_ipv4 => true})
      expect(sshable).to receive(:update).with({:host => "1.1.1.1"})
      expect { nx.wait_ipv4 }.to hop("wait_sshable")
    end
  end
end
