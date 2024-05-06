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
        {summary: _1.summary, logs: _1.details["logs"]["stderr"]}
      }
    })
  end
end
