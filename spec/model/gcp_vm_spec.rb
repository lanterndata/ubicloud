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
      expect(gcp_vm.host).to be_nil
    end

    it ".display_state" do
      expect(gcp_vm.display_state).to be_nil
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
      expect(gcp_vm).to receive(:family).and_return("n1-standard")
      expect(gcp_vm).to receive(:cores).and_return(2)
      expect(gcp_vm.display_size).to eq("n1-standard-2")
    end

    it ".inhost_name" do
      expect(gcp_vm.inhost_name).to eq("pvr1mcnh")
    end
  end

  describe "is_stopped" do
    it "returns false" do
      api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(api)
      expect(api).to receive(:get_vm).with(gcp_vm.name, "#{gcp_vm.location}-a").and_return({"status" => "RUNNING"})
      expect(gcp_vm.is_stopped?).to be(false)
    end

    it "returns true" do
      api = instance_double(Hosting::GcpApis)
      expect(Hosting::GcpApis).to receive(:new).and_return(api)
      expect(api).to receive(:get_vm).with(gcp_vm.name, "#{gcp_vm.location}-a").and_return({"status" => "TERMINATED"})
      expect(gcp_vm.is_stopped?).to be(true)
    end
  end
end
