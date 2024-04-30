# frozen_string_literal: true

require "forwardable"

class Prog::Lantern::LanternTimelineNexus < Prog::Base
  subject_is :lantern_timeline

  extend Forwardable
  def_delegators :lantern_timeline, :blob_storage_client

  semaphore :destroy

  def self.assemble(parent_id: nil)
    if parent_id && (LanternTimeline[parent_id]).nil?
      fail "No existing parent"
    end

    DB.transaction do
      lantern_timeline = LanternTimeline.create_with_id(
        parent_id: parent_id
      )
      Strand.create(prog: "Lantern::LanternTimelineNexus", label: "start") { _1.id = lantern_timeline.id }
    end
  end

  def before_run
    when_destroy_set? do
      if strand.label != "destroy"
        hop_destroy
      end
    end
  end

  label def start
    api = Hosting::GcpApis.new
    service_account = api.create_service_account("lt-#{lantern_timeline.ubid}", "Service Account for Timeline #{lantern_timeline.ubid}")
    key = api.export_service_account_key(service_account["email"])
    api.allow_bucket_usage_by_prefix(service_account["email"], Config.lantern_backup_bucket, lantern_timeline.ubid)
    lantern_timeline.update(service_account_name: service_account["email"], gcp_creds_b64: key)
    hop_wait_leader
  end

  label def wait_leader
    hop_destroy if lantern_timeline.leader.nil?

    nap 5 if lantern_timeline.leader.strand.label != "wait"
    hop_wait
  end

  label def wait
    if lantern_timeline.need_backup?
      hop_take_backup
    end

    # For the purpose of missing backup pages, we act like the very first backup
    # is taken at the creation, which ensures that we would get a page if and only
    # if no backup is taken for 2 days.
    latest_backup_completed_at = lantern_timeline.backups.map { |hsh| hsh[:last_modified] }.max || lantern_timeline.created_at
    if lantern_timeline.leader && latest_backup_completed_at < Time.now - 2 * 24 * 60 * 60 # 2 days
      Prog::PageNexus.assemble("Missing backup at #{lantern_timeline}!", [lantern_timeline.ubid], "MissingBackup", lantern_timeline.id)
    else
      Page.from_tag_parts("MissingBackup", lantern_timeline.id)&.incr_resolve
    end

    nap 20 * 60
  end

  label def take_backup
    # It is possible that we already started backup but crashed before saving
    # the state to database. Since backup taking is an expensive operation,
    # we check if backup is truly needed.
    if lantern_timeline.need_backup?
      lantern_timeline.take_backup
    end

    hop_wait
  end

  label def destroy
    decr_destroy
    destroy_blob_storage
    if !lantern_timeline.children.empty?
      lantern_timeline.children.map do |timeline|
        timeline.parent_id = nil
        timeline.save_changes
      end
    end
    lantern_timeline.destroy
    pop "lantern timeline is deleted"
  end

  def destroy_blob_storage
    # TODO
    # Remove all backups
    if lantern_timeline.service_account_name
      api = Hosting::GcpApis.new
      api.remove_service_account(lantern_timeline.service_account_name)
    end
  end
end
