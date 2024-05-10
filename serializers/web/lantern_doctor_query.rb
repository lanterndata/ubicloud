# frozen_string_literal: true

class Serializers::Web::LanternDoctorQuery < Serializers::Base
  def self.base(query)
    {
      id: query.id,
      name: query.name,
      label: "#{query.name} - #{query.doctor.resource.name} (#{query.doctor.resource.label})",
      type: query.type,
      condition: query.condition,
      last_checked: query.last_checked,
      schedule: query.schedule,
      db_name: query.db_name,
      sql: query.sql,
      severity: query.severity
    }
  end

  structure(:default) do |query|
    base(query)
  end

  structure(:detailed) do |query|
    base(query).merge({
      incidents: query.new_and_active_pages.map {
        {path: _1.path, id: _1.id, status: _1.status, summary: _1.page.summary, error: _1.error, output: _1.output, triggered_at: _1.created_at}
      }
    })
  end
end
