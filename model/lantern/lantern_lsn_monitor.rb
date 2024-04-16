# frozen_string_literal: true

require_relative "../../model"

class LanternLsnMonitor < Sequel::Model
  plugin :insert_conflict
end
