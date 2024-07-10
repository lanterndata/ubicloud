# frozen_string_literal: true

require_relative "../../model"

class LanternDoctorPage < Sequel::Model
  one_to_one :page, class: Page, key: :id, primary_key: :page_id
  many_to_one :query, class: LanternDoctorQuery, key: :query_id, primary_key: :id

  include ResourceMethods

  def self.create_incident(query, db_name, vm_name, err: "", output: "")
    pg = Prog::PageNexus.assemble_with_logs("Healthcheck: #{query.name} failed on #{query.doctor.resource.name} - #{query.doctor.resource.label} (#{db_name} - #{vm_name})", [query.ubid, query.doctor.ubid], {"stderr" => err, "stdout" => output}, query.severity, "LanternDoctorQueryFailed", query.id, db_name, vm_name)
    LanternDoctorPage.create_with_id(
      query_id: query.id,
      page_id: pg.id,
      status: "new",
      db: db_name,
      vm_name: vm_name
    )
  end

  def path
    "#{query.doctor.resource.path}/doctor/incidents/#{id}"
  end

  def error
    page.details["logs"]["stderr"]
  end

  def output
    page.details["logs"]["stdout"]
  end

  def ack
    update(status: "acknowledged")
  end

  def trigger
    update(status: "triggered")
  end

  def resolve
    page.incr_resolve
    update(status: "resolved")
  end
end
