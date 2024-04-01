# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Serializers::Api::Lantern do
  let(:lantern) { LanternServer.new(
    name: "lantern-1",
    location: "us-central1",
    lantern_version: "0.2.2",
    extras_version: "0.1.2",
    minor_version: "1",
    org_id: 1,
    target_vm_size: "standard-2",
    target_storage_size_gib: 10,
    debug: false,
    enable_telemetry: false,
    postgres_password: "test123",
    app_env: "production",
    db_name: "test",
    db_user: "test-user",
    db_user_password: "test-user-pass",
    repl_user: "repl-user",
    repl_password: "repl-pass",
  ).tap { _1.id = "69c0f4cd-99c1-8ed0-acfe-7b013ce2fa0b" } }

  it "correctly serializes Lantern Server" do
    gcp_vm = instance_double(GcpVm, domain: "example.com")
    expect(gcp_vm).to receive(:location).and_return("us-central1")
    sshable = instance_double(Sshable, host: "127.0.0.1")
    expect(gcp_vm).to receive(:sshable).and_return(sshable).exactly(4).times
    expect(lantern).to receive(:gcp_vm).and_return(gcp_vm).exactly(7).times
    strand = instance_double(Strand, label: "wait")
    expect(lantern).to receive(:strand).and_return(strand).exactly(4).times
    data = described_class.new(:detailed).serialize(lantern)

    expect(data[:state]).to eq("running")
    expect(data[:connection_string]).to eq("postgres://postgres:test123@example.com:6432")
    expect(data[:vm_size]).to eq("standard-2")
    expect(data[:host]).to eq("127.0.0.1")
  end

  it "state should be creating without host" do
    gcp_vm = instance_double(GcpVm, domain: nil)
    expect(gcp_vm).to receive(:location).and_return("us-central1")
    sshable = instance_double(Sshable, host: "temp_test")
    expect(gcp_vm).to receive(:sshable).and_return(sshable).exactly(3).times
    expect(lantern).to receive(:gcp_vm).and_return(gcp_vm).exactly(5).times
    strand = instance_double(Strand, label: "creating")
    expect(lantern).to receive(:strand).and_return(strand).exactly(5).times
    data = described_class.new(:detailed).serialize(lantern)

    expect(data[:state]).to eq("creating")
    expect(data[:connection_string]).to eq(nil)
    expect(data[:vm_size]).to eq("standard-2")
    expect(data[:host]).to eq(nil)
  end

  it "should serialize array" do
    gcp_vm = instance_double(GcpVm, domain: nil)
    expect(gcp_vm).to receive(:location).and_return("us-central1").exactly(2).times
    sshable = instance_double(Sshable, host: "temp_test")
    expect(gcp_vm).to receive(:sshable).and_return(sshable).exactly(6).times
    expect(lantern).to receive(:gcp_vm).and_return(gcp_vm).exactly(10).times
    strand = instance_double(Strand, label: "creating")
    expect(lantern).to receive(:strand).and_return(strand).exactly(10).times

    data = described_class.new(:detailed).serialize([lantern, lantern])

    expect(data[0][:state]).to eq("creating")
    expect(data[1][:state]).to eq("creating")
    expect(data[0][:connection_string]).to eq(nil)
    expect(data[1][:connection_string]).to eq(nil)
  end
end
