# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Serializers::Api::Lantern do
  let(:lantern) {
    LanternResource.new(
      name: "lantern-1",
      location: "us-central1",
      org_id: 1,
      debug: false,
      enable_telemetry: false,
      superuser_password: "test123",
      app_env: "production",
      db_name: "test",
      db_user: "test-user",
      db_user_password: "test-user-pass",
      repl_user: "repl-user",
      repl_password: "repl-pass",
      ha_type: LanternResource::HaType::SYNC
    ).tap { _1.id = "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0b" }
  }

  it "correctly serializes Lantern Server" do
    leader = instance_double(LanternServer,
      domain: "db.lanern.dev",
      target_vm_size: "standard-2",
      target_storage_size_gib: 10,
      lantern_version: "0.2.2",
      extras_version: "0.1.2",
      minor_version: "1",
      display_state: "running",
      instance_type: "writer",
      hostname: "db.lantern.dev",
      connection_string: "postgres://postgres:test123@db.lantern.dev:6432")
    expect(lantern).to receive(:representative_server).and_return(leader).at_least(:once)
    data = described_class.new(:default).serialize(lantern)

    expect(data[:state]).to eq("running")
    expect(data[:connection_string]).to be_nil
    expect(data[:vm_size]).to eq("standard-2")
    expect(data[:host]).to eq("db.lantern.dev")
  end

  it "correctly serializes Lantern Server without representative_server" do
    instance_double(LanternServer,
      domain: "db.lanern.dev",
      target_vm_size: "standard-2",
      target_storage_size_gib: 10,
      lantern_version: "0.2.2",
      extras_version: "0.1.2",
      minor_version: "1",
      display_state: "running",
      instance_type: "writer",
      hostname: "db.lantern.dev",
      connection_string: "postgres://postgres:test123@db.lantern.dev:6432")
    expect(lantern).to receive(:representative_server).and_return(nil).at_least(:once)
    data = described_class.new(:default).serialize(lantern)

    expect(data[:state]).to eq("unavailable")
    expect(data[:connection_string]).to be_nil
    expect(data[:vm_size]).to be_nil
  end

  it "correctly serializes Lantern Server detailed" do
    leader = instance_double(LanternServer,
      id: "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0a",
      ubid: "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0c",
      domain: "db.lanern.dev",
      target_vm_size: "standard-2",
      target_storage_size_gib: 10,
      lantern_version: "0.2.2",
      extras_version: "0.1.2",
      minor_version: "1",
      display_state: "running",
      instance_type: "writer",
      hostname: "db.lantern.dev",
      connection_string: "postgres://postgres:test123@db.lantern.dev:6432",
      strand: instance_double(Strand, label: "wait"))
    expect(lantern).to receive(:representative_server).and_return(leader).at_least(:once)
    expect(lantern).to receive(:servers).and_return([leader]).at_least(:once)
    data = described_class.new(:detailed).serialize(lantern)

    expect(data[:state]).to eq("running")
    expect(data[:connection_string]).to eq("postgres://postgres:test123@db.lantern.dev:6432")
    expect(data[:vm_size]).to eq("standard-2")
    expect(data[:host]).to eq("db.lantern.dev")
    expect(data[:servers][0][:connection_string]).to eq("postgres://postgres:test123@db.lantern.dev:6432")
  end

  it "serializes array" do
    leader = instance_double(LanternServer,
      domain: "db.lanern.dev",
      target_vm_size: "standard-2",
      target_storage_size_gib: 10,
      lantern_version: "0.2.2",
      extras_version: "0.1.2",
      minor_version: "1",
      display_state: "running",
      instance_type: "writer",
      hostname: "db.lantern.dev",
      connection_string: "postgres://postgres:test123@db.lantern.dev:6432")
    expect(lantern).to receive(:representative_server).and_return(leader).at_least(:once)
    data = described_class.new(:default).serialize([lantern, lantern])

    expect(data[0][:state]).to eq("running")
    expect(data[1][:state]).to eq("running")
    expect(data[0][:connection_string]).to be_nil
    expect(data[1][:connection_string]).to be_nil
  end
end
