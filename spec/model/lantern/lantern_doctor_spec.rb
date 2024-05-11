# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe LanternDoctor do
  subject(:lantern_doctor) {
    described_class.new do |r|
      r.id = "6181ddb3-0002-8ad0-9aeb-084832c9273b"
    end
  }

  before do
    allow(LanternServer).to receive(:get_vm_image).and_return(Config.gcp_default_image)
  end

  describe "#system_queries" do
    it "returns cached queries" do
      expect(lantern_doctor).to receive(:system_queries).and_return([instance_double(LanternDoctorQuery)])
      expect(lantern_doctor.system_queries.size).to be(1)
    end

    it "fetches system queries" do
      expect(LanternDoctorQuery).to receive(:where).with(type: "system").and_return(instance_double(Sequel::Dataset, all: [instance_double(LanternDoctorQuery), instance_double(LanternDoctorQuery)]))
      expect(lantern_doctor.system_queries.size).to be(2)
    end
  end

  describe "#has_system_query?" do
    it "returns true if system query exists in query list" do
      system_query = instance_double(LanternDoctorQuery, id: "test-parent-id")
      query_list = [instance_double(LanternDoctorQuery, parent_id: "test-parent-id")]
      expect(lantern_doctor.has_system_query?(query_list, system_query)).to be(true)
    end

    it "returns false if system query does not exist in query list" do
      system_query = instance_double(LanternDoctorQuery, id: "test-parent-id")
      query_list = [instance_double(LanternDoctorQuery, parent_id: "test-parent-id2"), instance_double(LanternDoctorQuery, parent_id: nil)]
      expect(lantern_doctor.has_system_query?(query_list, system_query)).to be(false)
    end
  end

  describe "#sync_system_queries" do
    it "creates new system query if not exists" do
      system_queries = [instance_double(LanternDoctorQuery, id: "test-parent-id", response_type: "rows"), instance_double(LanternDoctorQuery, id: "test-parent-id2", response_type: "bool")]
      query_list = [instance_double(LanternDoctorQuery, parent_id: "test-parent-id2"), instance_double(LanternDoctorQuery, parent_id: nil)]
      expect(lantern_doctor).to receive(:queries).and_return(query_list)
      expect(lantern_doctor).to receive(:system_queries).and_return(system_queries)
      new_query = instance_double(LanternDoctorQuery, parent_id: "test-parent-id")
      expect(LanternDoctorQuery).to receive(:create_with_id).with(parent_id: "test-parent-id", doctor_id: lantern_doctor.id, type: "user", response_type: "rows", condition: "unknown").and_return(new_query)
      expect { lantern_doctor.sync_system_queries }.not_to raise_error
    end
  end

  describe "#should_run" do
    it "returns true" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, representative_server: instance_double(LanternServer, display_state: "running", strand: instance_double(Strand, label: "wait")))).at_least(:once)
      expect(lantern_doctor.should_run?).to be(true)
    end

    it "returns false if not running" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, representative_server: instance_double(LanternServer, display_state: "stopped", strand: instance_double(Strand, label: "start")))).at_least(:once)
      expect(lantern_doctor.should_run?).to be(false)
    end

    it "returns false" do
      expect(lantern_doctor).to receive(:resource).and_return(instance_double(LanternResource, representative_server: instance_double(LanternServer, display_state: "running", strand: instance_double(Strand, label: "start")))).at_least(:once)
      expect(lantern_doctor.should_run?).to be(false)
    end

    it "returns false if no resource" do
      expect(lantern_doctor).to receive(:resource).and_return(nil)
      expect(lantern_doctor.should_run?).to be(false)
    end
  end
end
