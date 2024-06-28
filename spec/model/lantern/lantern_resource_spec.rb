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

  describe "#create_ddl_log" do
    it "create ddl log table" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query_all).with(a_string_matching(/ddl_log/))
      expect { lantern_resource.create_ddl_log }.not_to raise_error
    end
  end

  describe "#listen_ddl_log" do
    it "listends ddl log table" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query_all).with(a_string_matching(/execute_ddl_command/))
      expect { lantern_resource.listen_ddl_log }.not_to raise_error
    end
  end

  describe "#set_to_readonly" do
    it "convert server to readonly" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query).with(a_string_matching(/default_transaction_read_only TO on/))
      expect { lantern_resource.set_to_readonly }.not_to raise_error
    end

    it "convert server to writable" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query).with(a_string_matching(/default_transaction_read_only TO off/))
      expect { lantern_resource.set_to_readonly(status: "off") }.not_to raise_error
    end
  end

  describe "#create_replication_slot" do
    it "creates new logical replication slot" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query).with("SELECT lsn FROM pg_create_logical_replication_slot('test', 'pgoutput');").and_return("0/6002748 \n")
      expect(lantern_resource.create_logical_replication_slot("test")).to eq("0/6002748")
    end

    it "creates new physical replication slot" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query).with("SELECT lsn FROM pg_create_physical_replication_slot('test', true);").and_return("0/6002748 \n")
      expect(lantern_resource.create_physical_replication_slot("test")).to eq("0/6002748")
    end
  end

  describe "#drop_replication_slot" do
    it "drops replication slot" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query).with("SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name='test';")
      expect { lantern_resource.delete_replication_slot("test") }.not_to raise_error
    end
  end

  describe "#create_publication" do
    it "creates new publication" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query_all).with("CREATE PUBLICATION test FOR ALL TABLES")
      expect { lantern_resource.create_publication("test") }.not_to raise_error
    end
  end

  describe "#create_and_enable_subscription" do
    it "creates new subscription" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:list_all_databases).and_return(["db1", "db2"])
      expect(lantern_resource.representative_server).to receive(:run_query).with(a_string_matching(/CREATE SUBSCRIPTION/), db: "db1")
      expect(lantern_resource.representative_server).to receive(:run_query).with(a_string_matching(/CREATE SUBSCRIPTION/), db: "db2")
      expect(lantern_resource).to receive(:connection_string).and_return("postgres://localhost:5432").at_least(:once)
      expect(lantern_resource).to receive(:parent).and_return(lantern_resource).at_least(:once)
      expect { lantern_resource.create_and_enable_subscription }.not_to raise_error
    end
  end

  describe "#disable_logical_subscription" do
    it "disables subscription" do
      representative_server = instance_double(LanternServer)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      expect(lantern_resource.representative_server).to receive(:run_query_all).with("ALTER SUBSCRIPTION sub_#{lantern_resource.ubid} DISABLE")
      expect { lantern_resource.disable_logical_subscription }.not_to raise_error
    end
  end

  describe "#create_logical_replica" do
    it "create logical replica with current version" do
      representative_server = instance_double(LanternServer,
        target_vm_size: "n1-standard-1",
        target_storage_size_gib: 120,
        lantern_version: Config.lantern_default_version,
        extras_version: Config.lantern_extras_default_version,
        minor_version: Config.lantern_minor_default_version)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      timeline = instance_double(LanternTimeline,
        latest_restore_time: Time.new)
      expect(lantern_resource).to receive(:timeline).and_return(timeline).at_least(:once)
      expect(lantern_resource).to receive(:create_logical_replication_slot)
      expect(lantern_resource).to receive(:create_ddl_log)
      expect(lantern_resource).to receive(:create_publication)
      expect(Prog::Lantern::LanternResourceNexus).to receive(:assemble).with(hash_including(
        parent_id: lantern_resource.id,
        version_upgrade: true,
        logical_replication: true,
        lantern_version: representative_server.lantern_version,
        extras_version: representative_server.extras_version,
        minor_version: representative_server.minor_version
      ))
      expect { lantern_resource.create_logical_replica }.not_to raise_error
    end

    it "create logical replica with specified version" do
      representative_server = instance_double(LanternServer,
        target_vm_size: "n1-standard-1",
        target_storage_size_gib: 120)
      expect(lantern_resource).to receive(:representative_server).and_return(representative_server).at_least(:once)
      timeline = instance_double(LanternTimeline,
        latest_restore_time: Time.new)
      expect(lantern_resource).to receive(:timeline).and_return(timeline).at_least(:once)
      expect(lantern_resource).to receive(:create_logical_replication_slot)
      expect(lantern_resource).to receive(:create_ddl_log)
      expect(lantern_resource).to receive(:create_publication)
      expect(Prog::Lantern::LanternResourceNexus).to receive(:assemble).with(hash_including(
        parent_id: lantern_resource.id,
        version_upgrade: true,
        logical_replication: true,
        lantern_version: "0.3.0",
        extras_version: "0.2.6",
        minor_version: "1"
      ))
      expect { lantern_resource.create_logical_replica(lantern_version: "0.3.0", extras_version: "0.2.6", minor_version: "1") }.not_to raise_error
    end
  end

  describe "#sync_sequences_with_parent" do
    it "syncs sequences with parent" do
      representative_server = instance_double(LanternServer)
      parent_representative_server = instance_double(LanternServer)
      parent = instance_double(described_class, representative_server: parent_representative_server)
      databases = ["db1", "db2"]
      query_result = "public,seq1,100\npublic,seq2,200"

      allow(lantern_resource).to receive_messages(representative_server: representative_server, parent: parent)
      allow(representative_server).to receive(:list_all_databases).and_return(databases)
      allow(parent_representative_server).to receive(:run_query).with(anything, db: "db1").and_return(query_result)
      allow(parent_representative_server).to receive(:run_query).with(anything, db: "db2").and_return(query_result)

      statements_db1 = [
        "SELECT setval('public.seq1', 100);",
        "SELECT setval('public.seq2', 200);"
      ]
      statements_db2 = statements_db1 # identical statements for the test

      expect(representative_server).to receive(:run_query).with(statements_db1, db: "db1")
      expect(representative_server).to receive(:run_query).with(statements_db2, db: "db2")

      expect { lantern_resource.sync_sequences_with_parent }.not_to raise_error
    end
  end
end
