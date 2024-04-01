# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GcpVm do
  subject(:gcp_vm) {
    described_class.new(
      name: "vm1",
      location: "us-central1"
    ) { _1.id = "c068cac7-ed45-82db-bf38-a003582b36ee" }
  }

  describe "instance properties" do
    it ".hyper_tag_name" do
      project = instance_double(Project, ubid: "c068cac7-ed45-82db-bf38-a003582b36eb")
      expect(gcp_vm.hyper_tag_name(project)).to eq("project/#{project.ubid}/location/us-central1/gcp_vm/vm1")
    end

    it ".path" do
      expect(gcp_vm.path).to eq("/location/us-central1/gcp_vm/vm1")
    end

    it ".host" do
      expect(gcp_vm).to receive(:sshable).and_return(instance_double(Sshable, host: "127.0.0.1"))
      expect(gcp_vm.host).to eq("127.0.0.1")
    end

    it ".host when no host" do
      expect(gcp_vm).to receive(:sshable).and_return(nil)
      expect(gcp_vm.host).to eq(nil)
    end

    it ".display_state" do
      expect(gcp_vm.display_state).to eq(nil)
    end

    it ".display_state when destroy set" do
      expect(gcp_vm).to receive(:destroy_set?).and_return(true)
      expect(gcp_vm.display_state).to eq("deleting")
    end

    it ".mem_gib_ratio x64" do
      expect(gcp_vm).to receive(:arch).and_return("amd64")
      expect(gcp_vm.mem_gib_ratio).to eq(8)
    end

    it ".mem_gib_ratio arm64" do
      expect(gcp_vm).to receive(:arch).and_return("arm64")
      expect(gcp_vm.mem_gib_ratio).to eq(3.2)
    end

    it ".display_size" do
      expect(gcp_vm).to receive(:family).and_return("standard")
      expect(gcp_vm).to receive(:cores).and_return(2)
      expect(gcp_vm.display_size).to eq("standard-2")
    end

    it ".inhost_name" do
      expect(gcp_vm.inhost_name).to eq("pvr1mcnh")
    end
  end
end
