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
    vm = GcpVm.new_with_id(family: "standard", cores: 1, name: "dummy-vm", arch: "x64", location: "us-central1", storage_size_gib: 50, boot_image: Config.gcp_default_image)
    vm
  }
  let(:prj) { Project.create_with_id(name: "default", provider: "gcp").tap { _1.associate_with_project(_1) } }

  before do
    creds = instance_double(Google::Auth::GCECredentials)
    allow(creds).to receive(:apply).and_return({})
    allow(Google::Auth).to receive(:get_application_default).and_return(creds)
  end

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
      st = described_class.assemble("some_ssh_key", prj.id, size: "n1-standard-4", arch: "arm64")
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

  describe "#create_vm" do
    it "Hops to create_vm on start" do
      expect(nx).to receive(:register_deadline).with(:wait, 10 * 60)
      expect { nx.start }.to hop("create_vm")
    end

    it "Hops to wait_create_vm" do
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      frame = {"labels" => {"parent" => "test-label"}}
      expect(gcp_api).to receive(:create_vm).with("dummy-vm", "us-central1-a", gcp_vm.boot_image, nil, nil, "standard-1", 50, labels: frame["labels"])
      expect(nx).to receive(:frame).and_return(frame)
      expect(nx.strand).to receive(:stack).and_return([frame]).at_least(:once)
      expect(nx.strand).to receive(:modified!).with(:stack).at_least(:once)
      expect(nx.strand).to receive(:save_changes).at_least(:once)
      expect(gcp_vm).to receive(:strand).and_return(instance_double(Strand, prog: "GcpVm", stack: [{}])).at_least(:once)
      expect { nx.create_vm }.to hop("wait_create_vm")
    end

    it "Naps 10 seconds if vm is not running" do
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:get_vm).with("dummy-vm", "us-central1-a").and_return({"status" => "PROVISIONING"})
      expect(gcp_vm).to receive(:strand).and_return(instance_double(Strand, prog: "GcpVm", stack: [{}])).at_least(:once)
      expect { nx.wait_create_vm }.to nap(10)
    end

    it "hops to create_static_ipv4" do
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:get_vm).with("dummy-vm", "us-central1-a").and_return({"status" => "RUNNING"})
      expect(gcp_api).to receive(:create_static_ipv4).with("dummy-vm-addr", "us-central1").and_return({})
      expect(gcp_vm).to receive(:strand).and_return(instance_double(Strand, prog: "GcpVm", stack: [{}])).at_least(:once)
      expect(gcp_vm).to receive(:update).with(address_name: "dummy-vm-addr")
      expect { nx.wait_create_vm }.to hop("wait_ipv4")
    end

    it "naps if ip4 is not yet reserved" do
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_vm).to receive(:address_name).and_return("dummy-vm-addr")
      expect(gcp_api).to receive(:get_static_ipv4).with("dummy-vm-addr", "us-central1").and_return({"status" => "CREATING", "address" => "1.1.1.1"})
      expect { nx.wait_ipv4 }.to nap(10)
    end

    it "hops to wait_sshable after assigning ipv4" do
      sshable = instance_double(Sshable)
      expect(gcp_vm).to receive(:sshable).and_return(sshable)
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_vm).to receive(:address_name).and_return("dummy-vm-addr")
      expect(gcp_api).to receive(:get_static_ipv4).with("dummy-vm-addr", "us-central1").and_return({"status" => "RESERVED", "address" => "1.1.1.1"})
      expect(gcp_api).to receive(:delete_ephermal_ipv4).with("dummy-vm", "us-central1-a")
      expect(gcp_api).to receive(:assign_static_ipv4).with("dummy-vm", "1.1.1.1", "us-central1-a")
      expect(gcp_vm).to receive(:update).with({has_static_ipv4: true})
      expect(sshable).to receive(:update).with({host: "1.1.1.1"})
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
      expect(gcp_vm).to receive(:update).with({display_state: "running"})
      expect(Socket).to receive(:tcp).with("1.1.1.1", 22, connect_timeout: 1)
      expect { nx.wait_sshable }.to hop("wait")
    end
  end

  describe "#start_vm" do
    it "hops to wait_sshable after run" do
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:start_vm).with("dummy-vm", "us-central1-a").and_return({"status" => "DONE"})
      expect { nx.start_vm }.to hop("wait_sshable")
    end
  end

  describe "#stop_vm" do
    it "hops to wait after stop" do
      expect(gcp_vm).to receive(:update).with({display_state: "stopped"})
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api).at_least(:once)
      expect(gcp_api).to receive(:stop_vm).with("dummy-vm", "us-central1-a")
      expect(gcp_api).to receive(:get_vm).with("dummy-vm", "us-central1-a").and_return({"status" => "STOPPING"})
      expect { nx.stop_vm }.to hop("wait_vm_stopped")
      expect { nx.wait_vm_stopped }.to nap(5)
      expect(gcp_api).to receive(:get_vm).with("dummy-vm", "us-central1-a").and_return({"status" => "TERMINATED"})
      expect { nx.wait_vm_stopped }.to hop("wait")
    end
  end

  describe "#destroy" do
    it "exits after run destroy" do
      expect(gcp_vm).to receive(:has_static_ipv4).and_return(false)
      expect(gcp_vm).to receive(:destroy)
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:delete_vm).with("dummy-vm", "us-central1-a")
      expect(LanternDoctorPage).to receive(:where).and_return([])
      expect { nx.destroy }.to exit({"msg" => "gcp vm deleted"})
    end

    it "release ip4 if exists" do
      expect(gcp_vm).to receive(:has_static_ipv4).and_return(true)
      expect(gcp_vm).to receive(:destroy)
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:delete_vm).with("dummy-vm", "us-central1-a")
      expect(gcp_vm).to receive(:address_name).and_return("dummy-vm-addr")
      expect(gcp_api).to receive(:release_ipv4).with("dummy-vm-addr", "us-central1")
      page = instance_double(LanternDoctorPage)
      expect(page).to receive(:resolve)
      expect(LanternDoctorPage).to receive(:where).and_return([page])
      expect { nx.destroy }.to exit({"msg" => "gcp vm deleted"})
    end
  end

  describe "#wait" do
    it "hops to stop_vm" do
      expect(nx).to receive(:when_stop_vm_set?).and_yield
      expect(nx).to receive(:register_deadline).with(:wait, 5 * 60)
      expect(gcp_vm).to receive(:update).with(display_state: "stopping")
      expect { nx.wait }.to hop("stop_vm")
    end

    it "hops to start_vm" do
      expect(nx).to receive(:register_deadline).with(:wait, 5 * 60)
      expect(gcp_vm).to receive(:update).with(display_state: "starting")
      expect(nx).to receive(:when_start_vm_set?).and_yield
      expect { nx.wait }.to hop("start_vm")
    end

    it "hops to destroy" do
      expect(gcp_vm).to receive(:update).with(display_state: "deleting")
      expect(nx).to receive(:when_destroy_set?).and_yield
      expect { nx.wait }.to hop("destroy")
    end

    it "hops to update_storage" do
      expect(nx).to receive(:register_deadline).with(:wait, 5 * 60)
      expect(gcp_vm).to receive(:update).with(display_state: "updating")
      expect(nx).to receive(:when_update_storage_set?).and_yield
      expect { nx.wait }.to hop("update_storage")
    end

    it "hops to update_size" do
      expect(nx).to receive(:register_deadline).with(:wait, 5 * 60)
      expect(gcp_vm).to receive(:update).with(display_state: "updating")
      expect(nx).to receive(:when_update_size_set?).and_yield
      expect { nx.wait }.to hop("update_size")
    end

    it "naps 30s" do
      expect { nx.wait }.to nap(30)
    end
  end

  describe "#update_storage" do
    it "stops vm before updating" do
      expect(gcp_vm).to receive(:is_stopped?).and_return(false)
      expect { nx.update_storage }.to hop("stop_vm")
    end

    it "resizes vm disk" do
      expect(gcp_vm).to receive(:is_stopped?).and_return(true)
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:get_vm).with("dummy-vm", "us-central1-a").and_return({"disks" => [{"source" => "https://compute.googleapis.com/compute/v1/projects/test/zones/us-central1-a/disks/test-disk"}]})
      expect(gcp_api).to receive(:resize_vm_disk).with("us-central1-a", "https://compute.googleapis.com/compute/v1/projects/test/zones/us-central1-a/disks/test-disk", 50)
      expect { nx.update_storage }.to hop("start_vm")
    end

    it "resizes vm disk and hop to vm size update" do
      expect(gcp_vm).to receive(:is_stopped?).and_return(true)
      expect(nx).to receive(:when_update_size_set?).and_yield
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:get_vm).with("dummy-vm", "us-central1-a").and_return({"disks" => [{"source" => "https://compute.googleapis.com/compute/v1/projects/test/zones/us-central1-a/disks/test-disk"}]})
      expect(gcp_api).to receive(:resize_vm_disk).with("us-central1-a", "https://compute.googleapis.com/compute/v1/projects/test/zones/us-central1-a/disks/test-disk", 50)
      expect { nx.update_storage }.to hop("update_size")
    end
  end

  describe "#update_size" do
    it "hops to stop_vm" do
      expect(gcp_vm).to receive(:is_stopped?).and_return(false)
      expect { nx.update_size }.to hop("stop_vm")
    end

    it "updates vm size" do
      expect(gcp_vm).to receive(:is_stopped?).and_return(true)
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:update_vm_type).with("dummy-vm", "us-central1-a", "standard-1")

      expect { nx.update_size }.to hop("start_vm")
    end

    it "hops to update_storage after vm size update" do
      expect(gcp_vm).to receive(:is_stopped?).and_return(true)
      expect(nx).to receive(:when_update_storage_set?).and_yield
      gcp_api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(gcp_api)
      expect(gcp_api).to receive(:update_vm_type).with("dummy-vm", "us-central1-a", "standard-1")
      expect { nx.update_size }.to hop("update_storage")
    end
  end

  describe "properties" do
    it "has valid host" do
      sshable = instance_double(Sshable, host: "1.1.1.1")
      expect(gcp_vm).to receive(:sshable).and_return(sshable)
      expect(nx.host).to eq("1.1.1.1")
    end
  end
end
