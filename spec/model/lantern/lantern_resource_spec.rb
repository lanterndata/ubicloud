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

  it "returns failed as display state" do
    expect(lantern_resource).to receive(:display_state).and_return("failed")
    expect(lantern_resource.display_state).to eq("failed")
  end

  it "returns failover" do
    expect(lantern_resource).to receive(:servers).and_return([instance_double(LanternServer, display_state: "running", strand: instance_double(Strand, label: "wait")), instance_double(LanternServer, display_state: "failover", strand: instance_double(Strand, label: "take_over"))])
    expect(lantern_resource.display_state).to eq("failover")
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

  describe "#setup_service_account" do
    it "sets up service account and updates resource" do
      api = instance_double(Hosting::GcpApis)
      allow(Hosting::GcpApis).to receive(:new).and_return(api)
      allow(api).to receive_messages(create_service_account: {"email" => "test-sa"}, export_service_account_key: "test-key")
      expect(lantern_resource).to receive(:update).with(gcp_creds_b64: "test-key", service_account_name: "test-sa")
      expect { lantern_resource.setup_service_account }.not_to raise_error
    end
  end

  describe "#create_logging_table" do
    it "create bigquery table and gives access" do
      instance_double(LanternTimeline, ubid: "test")
      api = instance_double(Hosting::GcpApis)
      expect(lantern_resource).to receive(:big_query_table).and_return("test-table-name").at_least(:once)
      expect(lantern_resource).to receive(:service_account_name).and_return("test-sa").at_least(:once)

      allow(Hosting::GcpApis).to receive(:new).and_return(api)
      allow(api).to receive(:create_big_query_table)
      allow(api).to receive(:allow_access_to_big_query_dataset)
      allow(api).to receive(:allow_access_to_big_query_table)

      expect { lantern_resource.create_logging_table }.not_to raise_error
    end
  end

  describe "#allow_timeline_access_to_bucket" do
    it "allows access to bucket by prefix" do
      timeline = instance_double(LanternTimeline, ubid: "test")
      expect(lantern_resource).to receive(:gcp_creds_b64).and_return("test-creds")
      expect(lantern_resource).to receive(:service_account_name).and_return("test-sa")
      expect(lantern_resource).to receive(:timeline).and_return(timeline).at_least(:once)
      expect(timeline).to receive(:update).with(gcp_creds_b64: "test-creds")

      api = instance_double(Hosting::GcpApis)
      allow(Hosting::GcpApis).to receive(:new).and_return(api)
      allow(api).to receive(:allow_bucket_usage_by_prefix).with("test-sa", Config.lantern_backup_bucket, timeline.ubid)
      expect { lantern_resource.allow_timeline_access_to_bucket }.not_to raise_error
    end
  end

  describe "#big_query_table" do
    it "returns table name" do
      expect(lantern_resource.big_query_table).to eq("#{lantern_resource.name}_logs")
    end
  end
end
