# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe LanternResource do
  subject(:lantern_resource) {
    described_class.new(
      name: "pg-name",
      superuser_password: "dummy-password"
    ) { _1.id = "6181ddb3-0002-8ad0-9aeb-084832c9273b" }
  }

  it "returns connection string without ubid qualifier" do
    representative_server = instance_double(LanternServer)
    expect(lantern_resource).to receive(:representative_server).and_return(representative_server)
    expect(representative_server).to receive(:connection_string).and_return("postgres://postgres:dummy-password@pg-name.db.lanern.dev")
    expect(lantern_resource.connection_string).to eq("postgres://postgres:dummy-password@pg-name.db.lanern.dev")
  end

  it "returns connection string as nil if there is no server" do
    expect(lantern_resource).to receive(:representative_server).and_return(nil).at_least(:once)
    expect(lantern_resource.connection_string).to be_nil
  end

  it "returns running as display state if the database is ready" do
    representative_server = instance_double(LanternServer)
    expect(lantern_resource).to receive(:representative_server).and_return(representative_server)
    expect(representative_server).to receive(:display_state).and_return("running")
    expect(lantern_resource.display_state).to eq("running")
  end

  it "returns unavailable as display state if no representative_server" do
    expect(lantern_resource).to receive(:representative_server).and_return(nil)
    expect(lantern_resource.display_state).to eq("unavailable")
  end

  it "returns name from ubid" do
    expect(described_class.ubid_to_name(lantern_resource.id)).to eq("6181ddb3")
  end

  it "returns correct hypertag" do
    project = instance_double(Project, ubid: "test")
    expect(lantern_resource).to receive(:location).and_return("us-central1")
    expect(lantern_resource.hyper_tag_name(project)).to eq("project/test/location/us-central1/lantern/pg-name")
  end

  it "returns correct path" do
    expect(lantern_resource).to receive(:location).and_return("us-central1")
    expect(lantern_resource.path).to eq("/location/us-central1/lantern/pg-name")
  end

  describe "#required_standby_count" do
    it "returns 0 for none" do
      expect(lantern_resource).to receive(:ha_type).and_return(LanternResource::HaType::NONE)
      expect(lantern_resource.required_standby_count).to eq(0)
    end

    it "returns 1 for async" do
      expect(lantern_resource).to receive(:ha_type).and_return(LanternResource::HaType::ASYNC)
      expect(lantern_resource.required_standby_count).to eq(1)
    end

    it "returns 2 for sync" do
      expect(lantern_resource).to receive(:ha_type).and_return(LanternResource::HaType::SYNC)
      expect(lantern_resource.required_standby_count).to eq(2)
    end
  end

  describe "#dissociate_forks" do
    it "removes parents from forks" do
      child = instance_double(described_class, parent_id: lantern_resource.id, timeline: instance_double(LanternTimeline, parent_id: "test"))
      forks = [child]
      expect(lantern_resource).to receive(:forks).and_return(forks)
      expect(child).to receive(:update).with(parent_id: nil)
      expect(child.timeline).to receive(:update).with(parent_id: nil)

      expect { lantern_resource.dissociate_forks }.not_to raise_error
    end
  end
end
