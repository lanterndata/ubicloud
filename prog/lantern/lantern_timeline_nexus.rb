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
      # TODO::
      # Create new service account and export credentials json
      # Create base64 from credentials
      lantern_timeline = LanternTimeline.create_with_id(
        parent_id: parent_id,
        gcp_creds_b64: Config.gcp_creds_walg_b64
      )
      # Give access to bucket path to service account
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
      lantern_timeline.leader.gcp_vm.sshable.cmd("common/bin/daemonizer 'sudo lantern/bin/take_backup' take_postgres_backup")
      lantern_timeline.latest_backup_started_at = Time.now
      lantern_timeline.save_changes
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
    # Remove service account
  end
end
