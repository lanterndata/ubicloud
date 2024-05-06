# frozen_string_literal: true

class Serializers::Api::LanternDoctorQuery < Serializers::Base
  def self.base()
    {
      name: query.name,
      type: query.type,
      condition: query.condition
    }
  end

  structure(:default) do |pg|
    base(pg)
  end

  structure(:detailed) do |pg|
    base(pg).merge({
      incidents: []
    })
  end
end
