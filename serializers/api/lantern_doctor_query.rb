# frozen_string_literal: true

class Serializers::Api::LanternDoctorQuery < Serializers::Base
  def self.base(query)
    {
      id: query.id,
      name: query.name,
      type: query.type,
      condition: query.condition,
      last_checked: query.last_checked,
      schedule: query.schedule,
      db_name: query.db_name,
      severity: query.severity
    }
  end

  structure(:default) do |query|
    base(query)
  end

  structure(:detailed) do |query|
    base(query).merge({
      incidents: query.active_pages.map {
        {id: _1.id, summary: _1.page.summary, error: _1.error, output: _1.output, triggered_at: _1.created_at}
      }
    })
  end
end
