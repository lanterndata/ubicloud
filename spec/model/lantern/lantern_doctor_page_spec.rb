# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe LanternDoctorPage do
  subject(:lantern_doctor_page) {
    described_class.new do |r|
      r.id = "6181ddb3-0002-8ad0-9aeb-084832c9273b"
    end
  }

  let(:pg) {
    instance_double(
      Page,
      severity: "critical"
    )
  }

  describe "#create_incident" do
    it "creates page" do
      query = instance_double(LanternDoctorQuery, ubid: "test", id: "test-id", severity: "error", name: "test", doctor: instance_double(LanternDoctor, ubid: "test-doc-ubid", resource: instance_double(LanternResource, name: "test-res", label: "test-label")))
      db_name = "postgres"
      vm_name = "test"
      err = "test-err"
      output = "test-output"
      expect(Prog::PageNexus).to receive(:assemble_with_logs).with("Healthcheck: #{query.name} failed on #{query.doctor.resource.name} - #{query.doctor.resource.label} (#{db_name} - #{vm_name})", [query.ubid, query.doctor.ubid], {"stderr" => err, "stdout" => output}, query.severity, "LanternDoctorQueryFailed", query.id, db_name, vm_name).and_return(instance_double(Page, id: "test-pg-id"))
      doctor_page = instance_double(described_class)
      expect(described_class).to receive(:create_with_id).with(query_id: query.id, page_id: "test-pg-id", status: "new", db: db_name, vm_name: vm_name).and_return(doctor_page)
      expect(described_class.create_incident(query, db_name, vm_name, err: err, output: output)).to be(doctor_page)
    end
  end

  describe "#properties (logs)" do
    it "returns sterr and stdout from logs" do
      expect(lantern_doctor_page).to receive(:page).and_return(pg).at_least(:once)
      expect(pg).to receive(:details).and_return({"logs" => {"stdout" => "out", "stderr" => "err"}}).at_least(:once)
      expect(lantern_doctor_page.error).to eq("err")
      expect(lantern_doctor_page.output).to eq("out")
    end
  end

  describe "#actions (trigger, ack, resolve)" do
    it "triggers page" do
      expect(lantern_doctor_page).to receive(:update).with(status: "triggered")
      expect { lantern_doctor_page.trigger }.not_to raise_error
    end

    it "acks page" do
      expect(lantern_doctor_page).to receive(:update).with(status: "acknowledged")
      expect { lantern_doctor_page.ack }.not_to raise_error
    end

    it "resolves page" do
      expect(lantern_doctor_page).to receive(:update).with(status: "resolved")
      expect(lantern_doctor_page).to receive(:page).and_return(pg).at_least(:once)
      expect(pg).to receive(:incr_resolve)
      expect { lantern_doctor_page.resolve }.not_to raise_error
    end
  end

  describe "#path" do
    it "returns correct path" do
      query = instance_double(LanternDoctorQuery, ubid: "test", id: "test-id", severity: "error", name: "test", doctor: instance_double(LanternDoctor, ubid: "test-doc-ubid", resource: instance_double(LanternResource, name: "test-res", label: "test-label", path: "test-path")))
      expect(lantern_doctor_page).to receive(:query).and_return(query)
      expect(lantern_doctor_page.path).to eq("test-path/doctor/incidents/#{lantern_doctor_page.id}")
    end
  end
end
