# frozen_string_literal: true

require "forwardable"

class Prog::Lantern::LanternDoctorNexus < Prog::Base
  subject_is :lantern_doctor

  extend Forwardable
  def_delegators :lantern_doctor

  semaphore :destroy, :sync_system_queries

  def self.assemble
    DB.transaction do
      lantern_doctor = LanternDoctor.create_with_id
      Strand.create(prog: "Lantern::LanternDoctorNexus", label: "start") { _1.id = lantern_doctor.id }
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
    lantern_doctor.sync_system_queries
    hop_wait_resource
  end

  label def wait_resource
    nap 5 if lantern_doctor.resource&.strand&.label != "wait"
    hop_wait
  end

  label def wait
    if lantern_doctor.resource.nil?
      hop_destroy
    end

    when_sync_system_queries_set? do
      hop_sync_system_queries
    end

    lantern_doctor.queries.each { _1.run }
    nap 60
  end

  label def sync_system_queries
    decr_sync_system_queries
    lantern_doctor.sync_system_queries
    hop_wait
  end

  label def destroy
    decr_destroy

    lantern_doctor.failed_queries.each {
      _1.active_pages.each { |pg| pg.incr_resolve }
    }

    lantern_doctor.destroy
    pop "lantern doctor is deleted"
  end
end
