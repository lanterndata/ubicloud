# frozen_string_literal: true

require_relative "../../model"

class LanternResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :servers, class: LanternServer, key: :resource_id
  one_to_one :representative_server, class: LanternServer, key: :resource_id, conditions: Sequel.~(representative_at: nil)
  one_through_one :timeline, class: LanternTimeline, join_table: :lantern_server, left_key: :resource_id, right_key: :timeline_id

  dataset_module Authorization::Dataset
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :db_user_password
    enc.column :repl_password
  end

  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/lantern/#{name}"
  end

  def path
    "/location/#{location}/lantern/#{name}"
  end

  def display_state
    representative_server&.display_state || "unavailable"
  end

  def connection_string
    representative_server&.connection_string
  end

  def required_standby_count
    required_standby_count_map = {HaType::NONE => 0, HaType::ASYNC => 1, HaType::SYNC => 2}
    required_standby_count_map[ha_type]
  end

  module HaType
    NONE = "none"
    ASYNC = "async"
    SYNC = "sync"
  end
end
