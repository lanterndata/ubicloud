# frozen_string_literal: true

require_relative "../../model"

class LanternDoctor < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :resource, class: LanternResource, key: :doctor_id
  one_to_many :queries, key: :doctor_id, class: LanternDoctorQuery

  plugin :association_dependencies, queries: :destroy

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  def system_queries
    @system_queries ||= LanternDoctorQuery.where(type: "system")
  end

  def has_system_query?(queries, query)
    queries.any? { _1.parent_id == query.id }
  end

  def list_queries
    doctor_query_list = queries
    system_query_list = system_queries
    merged_queries = doctor_query_list

    system_query_list.each {
      if !has_system_query?(doctor_query_list, _1)
        doctor_query = LanternDoctorQuery.create_with_id(parent_id: _1.id, condition: "unknown", type: "system")
        doctor_query.parent = _1
        merged_queries.push(doctor_query)
      end
    }

    puts "Merged queries are ->>>>. #{merged_queries}"
    merged_queries
  end

  def list_incidents
    # TODO::
    # Find all unhealthy queries
    # Get all pages for that queries
    # Map results
    []
  end
end
