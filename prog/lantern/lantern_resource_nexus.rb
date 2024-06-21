# frozen_string_literal: true

require "forwardable"

require_relative "../../lib/util"

class Prog::Lantern::LanternResourceNexus < Prog::Base
  subject_is :lantern_resource

  extend Forwardable
  def_delegators :lantern_resource, :servers, :representative_server

  semaphore :destroy, :swap_leaders_with_parent

  def self.assemble(project_id:, location:, name:, target_vm_size:, target_storage_size_gib:, ubid: LanternResource.generate_ubid, ha_type: LanternResource::HaType::NONE, parent_id: nil, restore_target: nil, recovery_target_lsn: nil,
    org_id: nil, db_name: "postgres", db_user: "postgres", db_user_password: nil, superuser_password: nil, repl_password: nil, app_env: Config.rack_env,
    lantern_version: Config.lantern_default_version, extras_version: Config.lantern_extras_default_version, minor_version: Config.lantern_minor_default_version, domain: nil, enable_debug: false,
    label: "", version_upgrade: false, logical_replication: false)
    unless (project = Project[project_id])
      fail "No existing project"
    end

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

        if !version_upgrade
          lantern_version = parent.representative_server.lantern_version
          extras_version = parent.representative_server.extras_version
          minor_version = parent.representative_server.minor_version
        end

        target_storage_size_gib = parent.representative_server.target_storage_size_gib
      end

      lantern_doctor = Prog::Lantern::LanternDoctorNexus.assemble

      lantern_resource = LanternResource.create(
        project_id: project_id, location: location, name: name, org_id: org_id, app_env: app_env,
        superuser_password: superuser_password, ha_type: ha_type, parent_id: parent_id,
        restore_target: restore_target, db_name: db_name, db_user: db_user,
        db_user_password: db_user_password, repl_user: repl_user, repl_password: repl_password,
        label: label, doctor_id: lantern_doctor.id, recovery_target_lsn: recovery_target_lsn, version_upgrade: version_upgrade,
        logical_replication: logical_replication
      ) { _1.id = ubid.to_uuid }
      lantern_resource.associate_with_project(project)

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

      lantern_resource.required_standby_count.times do
        Prog::Lantern::LanternServerNexus.assemble(
          resource_id: lantern_resource.id,
          timeline_id: timeline_id,
          timeline_access: "fetch",
          lantern_version: lantern_version,
          extras_version: extras_version,
          minor_version: minor_version,
          target_vm_size: target_vm_size,
          target_storage_size_gib: target_storage_size_gib
        )
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
    lantern_resource.setup_service_account
    lantern_resource.create_logging_table

    if lantern_resource.parent_id.nil?
      lantern_resource.allow_timeline_access_to_bucket
      register_deadline(:wait, 10 * 60)
    else
      register_deadline(:wait, 120 * 60)
    end

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

    if lantern_resource.logical_replication
      hop_enable_logical_replication
    end

    hop_wait
  end

  label def enable_logical_replication
    lantern_resource.listen_ddl_log
    lantern_resource.create_and_enable_subscription
    hop_wait
  end

  label def wait
    # Create missing standbys
    (lantern_resource.required_standby_count + 1 - lantern_resource.servers.count).times do
      Prog::Lantern::LanternServerNexus.assemble(
        resource_id: lantern_resource.id,
        lantern_version: lantern_resource.representative_server.lantern_version,
        extras_version: lantern_resource.representative_server.extras_version,
        minor_version: lantern_resource.representative_server.minor_version,
        target_vm_size: lantern_resource.representative_server.target_vm_size,
        target_storage_size_gib: lantern_resource.representative_server.target_storage_size_gib,
        timeline_id: lantern_resource.timeline.id,
        timeline_access: "fetch"
      )
    end

    if lantern_resource.display_state == "failed"
      lantern_resource.update(display_state: nil)
    end

    when_swap_leaders_with_parent_set? do
      if lantern_resource.parent.nil?
        decr_swap_leaders_with_parent
      else
        lantern_resource.update(display_state: "failover")
        lantern_resource.parent.update(display_state: "failover")
        register_deadline(:wait, 10 * 60)
        hop_swap_leaders_with_parent
      end
    end

    nap 30
  end

  label def update_hosts
    current_master = lantern_resource.parent.representative_server
    current_master_domain = current_master.domain
    new_master_domain = lantern_resource.representative_server.domain

    lantern_resource.representative_server.update(domain: current_master_domain)
    current_master.update(domain: new_master_domain)

    # update display_states
    lantern_resource.update(display_state: nil)
    lantern_resource.parent.update(display_state: nil)

    # remove fork association so parent can be deleted
    lantern_resource.update(parent_id: nil)
    lantern_resource.timeline.update(parent_id: nil)
    hop_wait
  end

  label def wait_swap_ip
    ready = false
    begin
      lantern_resource.representative_server.run_query("SELECT 1")
      ready = true
    rescue
    end

    if ready
      hop_update_hosts
    else
      nap 5
    end
  end

  label def swap_leaders_with_parent
    decr_swap_leaders_with_parent
    lantern_resource.parent.set_to_readonly
    lantern_resource.disable_logical_subscription
    lantern_resource.representative_server.vm.swap_ip(lantern_resource.parent.representative_server.vm)
    hop_wait_swap_ip
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
