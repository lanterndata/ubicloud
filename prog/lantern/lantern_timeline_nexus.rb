# frozen_string_literal: true

require "forwardable"

class Prog::Lantern::LanternTimelineNexus < Prog::Base
  subject_is :lantern_timeline

  extend Forwardable
  def_delegators :lantern_timeline, :blob_storage_client

  semaphore :destroy

  def self.assemble(gcp_creds_b64: nil, parent_id: nil)
    if parent_id && (LanternTimeline[parent_id]).nil?
      fail "No existing parent"
    end

    DB.transaction do
      lantern_timeline = LanternTimeline.create_with_id(
        parent_id: parent_id,
        gcp_creds_b64: gcp_creds_b64
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

    if lantern_timeline.need_cleanup?
      retain_after = (Time.new - (24 * 60 * 60 * Config.backup_retention_days)).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      cmd = "docker compose -f /var/lib/lantern/docker-compose.yaml exec -T -u root postgresql bash -c \"GOOGLE_APPLICATION_CREDENTIALS=/tmp/google-application-credentials-wal-g.json /opt/bitnami/postgresql/bin/wal-g delete retain FULL 7 --after #{retain_after} --confirm\""
      lantern_timeline.leader.vm.sshable.cmd("common/bin/daemonizer '#{cmd}' delete_old_backups")
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
    lantern_timeline.destroy
    pop "lantern timeline is deleted"
  end

  def destroy_blob_storage
    # TODO
    # Remove all backups
  end
end
