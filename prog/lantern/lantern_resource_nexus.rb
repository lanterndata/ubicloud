# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Lantern::LanternResourceNexus < Prog::Base
  subject_is :lantern_resource

  extend Forwardable
  def_delegators :lantern_resource, :servers, :representative_server

  semaphore :destroy

  def self.assemble(project_id:, location:, name:, target_vm_size:, target_storage_size_gib:, ha_type: LanternResource::HaType::NONE, parent_id: nil, restore_target: nil,
    org_id: nil, db_name: "postgres", db_user: "postgres", db_user_password: nil, superuser_password: nil, repl_password: nil, app_env: Config.rack_env,
    lantern_version: Config.lantern_default_version, extras_version: Config.lantern_extras_default_version, minor_version: Config.lantern_minor_default_version, domain: nil, enable_debug: false,
    label: "")
    unless (project = Project[project_id])
      fail "No existing project"
    end

    ubid = LanternResource.generate_ubid
    name ||= LanternResource.ubid_to_name(ubid)

    Validation.validate_location(location, project.provider)
    Validation.validate_name(name)
    !db_user.nil? && Validation.validate_db_user(db_user)
    !db_name.nil? && Validation.validate_db_name(db_name)
    Validation.validate_vm_size(target_vm_size)
    Validation.validate_lantern_ha_type(ha_type)

    DB.transaction do
      timeline_id = nil
      timeline_access = "push"
      repl_user = "repl_user"

      if parent_id.nil?
        repl_password ||= SecureRandom.urlsafe_base64(15)
        superuser_password ||= SecureRandom.urlsafe_base64(15)
        enable_debug ||= false
        db_user ||= "postgres"
        db_name ||= "postgres"

        if db_user != "postgres" && db_user_password.nil?
          db_user_password = SecureRandom.urlsafe_base64(15)
        end

        timeline_id = Prog::Lantern::LanternTimelineNexus.assemble.id
      else
        unless (parent = LanternResource[parent_id])
          fail "No existing parent"
        end

        restore_target = Validation.validate_date(restore_target, "restore_target")
        parent.timeline.refresh_earliest_backup_completion_time
        unless (earliest_restore_time = parent.timeline.earliest_restore_time) && earliest_restore_time <= restore_target &&
            parent.timeline.latest_restore_time && restore_target <= parent.timeline.latest_restore_time
          fail Validation::ValidationFailed.new({restore_target: "Restore target must be between #{earliest_restore_time} and #{parent.timeline.latest_restore_time}"})
        end

        timeline_id = parent.timeline.id
        timeline_access = "fetch"
        db_name = parent.db_name
        db_user = parent.db_user
        db_user_password = parent.db_user_password
        superuser_password = parent.superuser_password
        repl_user = parent.repl_user
        repl_password = parent.repl_password
        lantern_version = parent.representative_server.lantern_version
        extras_version = parent.representative_server.extras_version
        minor_version = parent.representative_server.minor_version
        target_storage_size_gib = parent.representative_server.target_storage_size_gib

      end

      lantern_doctor = Prog::Lantern::LanternDoctorNexus.assemble

      lantern_resource = LanternResource.create(
        project_id: project_id, location: location, name: name, org_id: org_id, app_env: app_env,
        superuser_password: superuser_password, ha_type: ha_type, parent_id: parent_id,
        restore_target: restore_target, db_name: db_name, db_user: db_user,
        db_user_password: db_user_password, repl_user: repl_user, repl_password: repl_password,
        label: label, doctor_id: lantern_doctor.id
      ) { _1.id = ubid.to_uuid }
      lantern_resource.associate_with_project(project)

      lantern_resource.setup_service_account
      lantern_resource.allow_access_to_big_query

      Prog::Lantern::LanternServerNexus.assemble(
        resource_id: lantern_resource.id,
        lantern_version: lantern_version,
        extras_version: extras_version,
        minor_version: minor_version,
        domain: domain,
        target_vm_size: target_vm_size,
        target_storage_size_gib: target_storage_size_gib,
        timeline_id: timeline_id,
        timeline_access: timeline_access,
        representative_at: Time.now
      )

      if parent_id.nil?
        lantern_resource.allow_timeline_access_to_bucket
      end

      lantern_resource.required_standby_count.times do
        Prog::Lantern::LanternServerNexus.assemble(resource_id: lantern_resource.id, timeline_id: timeline_id, timeline_access: "fetch")
      end

      Strand.create(prog: "Lantern::LanternResourceNexus", label: "start") { _1.id = lantern_resource.id }
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
    nap 5 unless representative_server.vm.strand.label == "wait"
    register_deadline(:wait, 10 * 60)
    # bud self.class, frame, :trigger_pg_current_xact_id_on_parent if lantern_resource.parent

    # hop_wait_trigger_pg_current_xact_id_on_parent
    hop_wait_servers
  end

  # TODO:: check why is this needed
  # label def trigger_pg_current_xact_id_on_parent
  #   lantern_resource.parent.representative_server.run_query("SELECT pg_current_xact_id()")
  #   pop "triggered pg_current_xact_id"
  # end
  #
  # label def wait_trigger_pg_current_xact_id_on_parent
  #   reap
  #   hop_wait_servers if leaf?
  #   nap 5
  # end

  label def wait_servers
    lantern_resource.set_failed_on_deadline
    nap 5 if servers.any? { _1.strand.label != "wait" }
    hop_wait
  end

  label def wait
    # Create missing standbys
    (lantern_resource.required_standby_count + 1 - lantern_resource.servers.count).times do
      Prog::Lantern::LanternServerNexus.assemble(resource_id: lantern_resource.id, timeline_id: lantern_resource.timeline.id, timeline_access: "fetch")
    end

    if lantern_resource.display_state == "failed"
      lantern_resource.update(display_state: nil)
    end

    nap 30
  end

  label def destroy
    register_deadline(nil, 5 * 60)

    decr_destroy

    strand.children.each { _1.destroy }
    unless servers.empty?
      servers.each(&:incr_destroy)
      nap 5
    end

    lantern_resource.doctor&.incr_destroy

    if lantern_resource.service_account_name
      api = Hosting::GcpApis.new
      api.remove_big_query_table(Config.lantern_log_dataset, lantern_resource.big_query_table)
      api.remove_service_account(lantern_resource.service_account_name)
    end

    lantern_resource.dissociate_with_project(lantern_resource.project)
    lantern_resource.destroy

    pop "lantern resource is deleted"
  end
end
