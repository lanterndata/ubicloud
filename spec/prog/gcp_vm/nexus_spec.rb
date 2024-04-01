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

    it "naps if ip4 is not yet reserved" do
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: JSON.dump({"status" => "RUNNING"}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:get, "https://compute.googleapis.com/compute/v1/projects/test-project/regions/us-central1/addresses/dummy-vm-addr").to_return(status: 200, body: JSON.dump({status: "CREATING", address: "1.1.1.1"}), headers: {"Content-Type" => "application/json"})
      expect { nx.wait_ipv4 }.to nap(10)
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

  describe "#wait_sshable" do
    it "naps if sshable not ready" do
      sshable = instance_double(Sshable, host: "1.1.1.1")
      expect(gcp_vm).to receive(:sshable).and_return(sshable)
      expect(Socket).to receive(:tcp).with("1.1.1.1", 22, connect_timeout: 1).and_raise Errno::ECONNREFUSED
      expect { nx.wait_sshable }.to nap(1)
    end

    it "update display_state to running when sshable ready" do
      sshable = instance_double(Sshable, host: "1.1.1.1")
      expect(gcp_vm).to receive(:sshable).and_return(sshable)
      expect(gcp_vm).to receive(:update).with({:display_state => "running"})
      expect(Socket).to receive(:tcp).with("1.1.1.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("wait")
    end
  end

  describe "#start_vm" do
    it "hops to wait_sshable after run" do
      expect(gcp_vm).to receive(:update).with({:display_state => "starting"})
      expect(gcp_vm).to receive(:update).with({:display_state => "running"})
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/ringed-griffin-394922/zones/us-central1-a/instances/dummy-vm/start").to_return(status: 200, body: "", headers: {})
      expect { nx.start_vm }.to hop("wait_sshable")
    end
  end

  describe "#stop_vm" do
    it "hops to wait after stop" do
      expect(gcp_vm).to receive(:update).with({:display_state => "stopping"})
      expect(gcp_vm).to receive(:update).with({:display_state => "stopped"})
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:post, "https://compute.googleapis.com/compute/v1/projects/ringed-griffin-394922/zones/us-central1-a/instances/dummy-vm/stop").to_return(status: 200, body: "", headers: {})
      expect { nx.stop_vm }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "exits after run destroy" do
      expect(gcp_vm).to receive(:has_static_ipv4).and_return(false)
      expect(gcp_vm).to receive(:update).with({:display_state => "deleting"})
      expect(gcp_vm).to receive(:destroy)
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:delete, "https://compute.googleapis.com/compute/v1/projects/ringed-griffin-394922/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: "", headers: {})
      expect { nx.destroy }.to exit({"msg" => "gcp vm deleted"})
    end

    it "release ip4 if exists" do
      expect(gcp_vm).to receive(:has_static_ipv4).and_return(true)
      expect(gcp_vm).to receive(:update).with({:display_state => "deleting"})
      expect(gcp_vm).to receive(:destroy)
      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(status: 200, body: JSON.dump({}), headers: {"Content-Type" => "application/json"})
      stub_request(:delete, "https://compute.googleapis.com/compute/v1/projects/ringed-griffin-394922/zones/us-central1-a/instances/dummy-vm").to_return(status: 200, body: "", headers: {})
      stub_request(:delete, "https://compute.googleapis.com/compute/v1/projects/ringed-griffin-394922/regions/us-central1/addresses/dummy-vm-addr")
      expect { nx.destroy }.to exit({"msg" => "gcp vm deleted"})
    end
  end

  describe "#wait" do
    it "hops to stop_vm" do
      expect(nx).to receive(:when_stop_vm_set?).and_yield
      expect { nx.wait }.to hop("stop_vm")
    end

    it "hops to start_vm" do
      expect(nx).to receive(:when_start_vm_set?).and_yield
      expect { nx.wait }.to hop("start_vm")
    end

    it "hops to destroy" do
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.wait }.to hop("destroy")
    end

    it "naps 30s" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "properties" do
    it "should have valid host" do
      sshable = instance_double(Sshable, host: "1.1.1.1")
      expect(gcp_vm).to receive(:sshable).and_return(sshable)
      expect(nx.host).to eq("1.1.1.1")
    end
  end
end
