# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Serializers::Web::LanternDoctorQuery do
  it "correctly serializes doctor query" do
    query = instance_double(LanternDoctorQuery,
      id: "test-id",
      name: "test-name",
      doctor: instance_double(LanternDoctor, resource: instance_double(LanternResource, name: "test-res-name", label: "test-label")),
      type: "user",
      condition: "healthy",
      last_checked: Time.new,
      schedule: "test-schedule",
      db_name: "test-db-name",
      sql: "SELECT 1",
      severity: "error")

    data = described_class.new(:default).serialize(query)

    expect(data[:label]).to eq("test-name - test-res-name (test-label)")
  end
end
