# frozen_string_literal: true

require_relative "../../model"

class LanternTimeline < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :children, key: :parent_id, class: self
  one_to_one :leader, class: LanternServer, key: :timeline_id, conditions: {instance_type: "writer"}

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :gcp_creds_b64
  end

  def bucket_name
    "gs://#{Config.lantern_backup_bucket}/#{ubid}"
  end

  def generate_walg_config
    # If there's no parent or leader
    # So this is reader instance without writer or backup point
    # That means this is a bug
    if parent.nil? && leader.nil?
      fail "standby instance without parent timeline"
    end

    gcp_creds_walg_push_b64, walg_gs_push_prefix = leader.nil? ? [nil, nil] : [gcp_creds_b64, bucket_name]
    gcp_creds_walg_pull_b64, walg_gs_pull_prefix = parent.nil? ? [nil, nil] : [parent.gcp_creds_b64, parent.bucket_name]

    {
      gcp_creds_walg_push_b64: gcp_creds_walg_push_b64,
      walg_gs_push_prefix: walg_gs_push_prefix,
      gcp_creds_walg_pull_b64: gcp_creds_walg_pull_b64,
      walg_gs_pull_prefix: walg_gs_pull_prefix
    }
  end

  def need_backup?
    return false if leader.nil?

    status = leader.gcp_vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup")
    return true if ["Failed", "NotStarted"].include?(status)
    return true if status == "Succeeded" && (latest_backup_started_at.nil? || latest_backup_started_at < Time.now - 60 * 60 * 24)

    false
  end

  def backups
    blob_storage_client
      .list_objects(Config.lantern_backup_bucket, "#{ubid}/basebackups_005/")
      .select { _1[:key].end_with?("backup_stop_sentinel.json") }
  end

  def latest_backup_label_before_target(target)
    backup = backups.sort_by { |hsh| hsh[:last_modified] }.reverse.find { _1[:last_modified] < target }
    fail "BUG: no backup found" unless backup
    backup[:key].delete_prefix("#{ubid}/basebackups_005/").delete_suffix("_backup_stop_sentinel.json")
  end

  def refresh_earliest_backup_completion_time
    update(earliest_backup_completed_at: backups.map { |hsh| hsh[:last_modified] }.min)
    earliest_backup_completed_at
  end

  # The "earliest_backup_completed_at" column is used to cache the value,
  # eliminating the need to query the blob storage every time. The
  # "earliest_backup_completed_at" value can be changed when a new backup is
  # created or an existing backup is deleted. It's nil when the server is
  # created, so we get it from the blob storage until the first backup
  # completed. Currently, we lack a backup cleanup feature. Once it is
  # implemented, we can invoke the "refresh_earliest_backup_completion_time"
  # method at the appropriate points.
  def earliest_restore_time
    if (earliest_backup = earliest_backup_completed_at || refresh_earliest_backup_completion_time)
      earliest_backup + 5 * 60
    end
  end

  def blob_storage_client
    Hosting::GcpApis.new
  end
end
