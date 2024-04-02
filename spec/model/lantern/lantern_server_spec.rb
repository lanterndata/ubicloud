# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe LanternServer do
  subject(:lantern_server) {
    described_class.new { _1.id = "c068cac7-ed45-82db-bf38-a003582b36ee" }
  }

  let(:gcp_vm) {
    instance_double(
      GcpVm,
      sshable: instance_double(Sshable),
      mem_gib: 8
    )
  }

  before do
    allow(lantern_server).to receive(:gcp_vm).and_return(gcp_vm)
  end

  it "Shows display state" do
    expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "setup domain"))
    expect(lantern_server.display_state).to eq("domain setup")

    expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "setup_ssl")).twice
    expect(lantern_server.display_state).to eq("ssl setup")

    expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "update_extension")).exactly(3).times
    expect(lantern_server.display_state).to eq("updating")

    expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait")).exactly(5).times
    expect(lantern_server.display_state).to eq("running")

    expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "destroy")).exactly(6).times
    expect(lantern_server.display_state).to eq("deleting")

    expect(lantern_server).to receive(:strand).and_return(instance_double(Strand, label: "wait_db_available")).exactly(4).times
    expect(lantern_server.display_state).to eq("unavailable")
  end
  it "returns name from ubid" do
    expect(LanternServer.ubid_to_name(lantern_server.id)).to eq("c068cac7")
  end

  it "runs query on vm" do
    expect(lantern_server.gcp_vm.sshable).to receive(:cmd).with("sudo lantern/bin/exec", stdin: "SELECT 1").and_return("1\n")
    expect(lantern_server.run_query("SELECT 1")).to eq("1")
  end
end
