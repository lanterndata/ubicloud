# frozen_string_literal: true

require_relative "../../model"

class LanternDoctor < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :resource, class: LanternResource, key: :doctor_id
  one_to_many :queries, key: :doctor_id, class: LanternDoctorQuery
  one_to_many :failed_queries, key: :doctor_id, class: LanternDoctorQuery, conditions: {condition: "failed"}

  plugin :association_dependencies, queries: :destroy

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy, :sync_system_queries

  def system_queries
    @system_queries ||= LanternDoctorQuery.where(type: "system").all
  end

  def has_system_query?(queries, query)
    queries.any? { _1.parent_id == query.id }
  end

  def should_run?
    return false unless resource
    resource.representative_server.display_state == "running" && resource.representative_server.strand.label == "wait"
  end

  def sync_system_queries
    doctor_query_list = queries
    system_query_list = system_queries

    system_query_list.each {
      if !has_system_query?(doctor_query_list, _1)
        LanternDoctorQuery.create_with_id(parent_id: _1.id, doctor_id: id, condition: "unknown", type: "user", response_type: _1.response_type)
      end
    }
  end
end
