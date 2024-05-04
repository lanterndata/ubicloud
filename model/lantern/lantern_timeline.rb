# frozen_string_literal: true

require_relative "../../model"

class LanternTimeline < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :parent, key: :parent_id, class: self
  one_to_many :children, key: :parent_id, class: self
  one_to_one :leader, class: LanternServer, key: :timeline_id, conditions: {timeline_access: "push"}

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  plugin :column_encryption do |enc|
    enc.column :gcp_creds_b64
  end

  def bucket_name
    "gs://#{Config.lantern_backup_bucket}/#{ubid}"
  end

  def latest_restore_time
    Time.now
  end

  def generate_walg_config
    {
      gcp_creds_b64: gcp_creds_b64,
      walg_gs_prefix: bucket_name
    }
  end

  def need_backup?
    return false if leader.nil?

    status = leader.vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup")
    return true if ["Failed", "NotStarted"].include?(status)
    return true if status == "Succeeded" && (latest_backup_started_at.nil? || latest_backup_started_at < Time.now - 60 * 60 * 24)

    false
  end

  def need_cleanup?
    return false if leader.nil?

    status = leader.vm.sshable.cmd("common/bin/daemonizer --check delete_old_backups")
    return true if ["Failed", "NotStarted", "Succeeded"].include?(status)

    false
  end

  def take_backup
    leader.vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/take_backup' take_postgres_backup")
    update(latest_backup_started_at: Time.now)
  end

  def take_manual_backup
    status = leader.vm.sshable.cmd("common/bin/daemonizer --check take_postgres_backup")

    if status == "InProgress"
      fail "Another backup is in progress please try again later"
    end

    yesterday = Time.now - 24 * 60 * 60

    last_backups = backups.select { _1[:last_modified] > yesterday }

    if last_backups.size > 5
      Prog::PageNexus.assemble_with_logs("Database v#{leader.resource.name} has more than 5 backups in last day", [ubid, leader.resource.ubid, leader.ubid], {}, "info", "LanternTooMuchBackups", ubid)
    end

    take_backup
  end

  def backups
    blob_storage_client
      .list_objects(Config.lantern_backup_bucket, "#{ubid}/basebackups_005/*_backup_stop_sentinel.json")
  end

  def backups_with_metadata
    storage_client = blob_storage_client
    mutex = Mutex.new
    thread_count = 8
    backup_list = backups
    results = []
    Array.new(thread_count) {
      Thread.new(backup_list, results) do |backup_list, results|
        while (backup = mutex.synchronize { backup_list.pop })
          metadata = storage_client.get_json_object(Config.lantern_backup_bucket, backup[:key])
          mutex.synchronize { results << {**backup, compressed_size: metadata["CompressedSize"], uncompressed_size: metadata["UncompressedSize"]} }
        end
      end
    }.each(&:join)
    results
  end

  def get_backup_label(key)
    key.delete_prefix("#{ubid}/basebackups_005/").delete_suffix("_backup_stop_sentinel.json")
  end

  def latest_backup_label_before_target(target)
    backup = backups.sort_by { |hsh| hsh[:last_modified] }.reverse.find { _1[:last_modified] < target }
    fail "BUG: no backup found" unless backup
    get_backup_label(backup[:key])
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
      earliest_backup + (Config.e2e_test? ? 0 : 5 * 60)
    end
  end

  def blob_storage_client
    Hosting::GcpApis.new
  end
end
