# frozen_string_literal: true

require_relative "../../model"

class LanternResource < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :project
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :forks, key: :parent_id, class: self
  one_to_many :servers, class: LanternServer, key: :resource_id
  one_to_one :representative_server, class: LanternServer, key: :resource_id, conditions: Sequel.~(representative_at: nil)
  one_through_one :timeline, class: LanternTimeline, join_table: :lantern_server, left_key: :resource_id, right_key: :timeline_id
  one_to_one :doctor, class: LanternDoctor, key: :id, primary_key: :doctor_id

  dataset_module Authorization::Dataset
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include DisplayStatusMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :superuser_password
    enc.column :db_user_password
    enc.column :repl_password
    enc.column :gcp_creds_b64
  end

  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def big_query_table
    "#{name}_logs"
  end

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/lantern/#{name}"
  end

  def path
    "/location/#{location}/lantern/#{name}"
  end

  def label
    (!super.nil? && !super.empty?) ? super : "no-label"
  end

  def display_state
    super || representative_server&.display_state || "unavailable"
  end

  def connection_string
    representative_server&.connection_string
  end

  def required_standby_count
    required_standby_count_map = {HaType::NONE => 0, HaType::ASYNC => 1, HaType::SYNC => 2}
    required_standby_count_map[ha_type]
  end

  def dissociate_forks
    forks.each {
      _1.update(parent_id: nil)
      _1.timeline.update(parent_id: nil)
    }
  end

  def setup_service_account
    api = Hosting::GcpApis.new
    service_account = api.create_service_account("lt-#{ubid}", "Service Account for Lantern #{name}")
    key = api.export_service_account_key(service_account["email"])
    update(gcp_creds_b64: key, service_account_name: service_account["email"])
  end

  def allow_timeline_access_to_bucket
    timeline.update(gcp_creds_b64: gcp_creds_b64)
    api = Hosting::GcpApis.new
    api.allow_bucket_usage_by_prefix(service_account_name, Config.lantern_backup_bucket, timeline.ubid)
  end

  def create_logging_table
    api = Hosting::GcpApis.new
    schema = [
      {name: "log_time", type: "TIMESTAMP", mode: "NULLABLE"},
      {name: "user_name", type: "STRING", mode: "NULLABLE"},
      {name: "database_name", type: "STRING", mode: "NULLABLE"},
      {name: "process_id", type: "INTEGER", mode: "NULLABLE"},
      {name: "connection_from", type: "STRING", mode: "NULLABLE"},
      {name: "session_id", type: "STRING", mode: "NULLABLE"},
      {name: "session_line_num", type: "INTEGER", mode: "NULLABLE"},
      {name: "command_tag", type: "STRING", mode: "NULLABLE"},
      {name: "session_start_time", type: "TIMESTAMP", mode: "NULLABLE"},
      {name: "virtual_transaction_id", type: "STRING", mode: "NULLABLE"},
      {name: "transaction_id", type: "INTEGER", mode: "NULLABLE"},
      {name: "error_severity", type: "STRING", mode: "NULLABLE"},
      {name: "sql_state_code", type: "STRING", mode: "NULLABLE"},
      {name: "duration", type: "FLOAT", mode: "NULLABLE"},
      {name: "message", type: "STRING", mode: "NULLABLE"},
      {name: "detail", type: "STRING", mode: "NULLABLE"},
      {name: "hint", type: "STRING", mode: "NULLABLE"},
      {name: "internal_query", type: "STRING", mode: "NULLABLE"},
      {name: "internal_query_pos", type: "INTEGER", mode: "NULLABLE"},
      {name: "context", type: "STRING", mode: "NULLABLE"},
      {name: "query", type: "STRING", mode: "NULLABLE"},
      {name: "query_pos", type: "INTEGER", mode: "NULLABLE"},
      {name: "location", type: "STRING", mode: "NULLABLE"},
      {name: "application_name", type: "STRING", mode: "NULLABLE"}
    ]
    api.create_big_query_table(Config.lantern_log_dataset, big_query_table, schema)
    # Add metadata viewer access
    api.allow_access_to_big_query_dataset(service_account_name, Config.lantern_log_dataset)
    # Add access to only this table
    api.allow_access_to_big_query_table(service_account_name, Config.lantern_log_dataset, big_query_table)
  end

  module HaType
    NONE = "none"
    ASYNC = "async"
    SYNC = "sync"
  end
end
