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

    if lantern_doctor.should_run?
      hop_run_queries
    end

    nap 60
  end

  label def run_queries
    lantern_doctor.queries.each do |query|
      next if !query.should_run?

      dbs = (query.db_name == "*") ? lantern_doctor.resource.representative_server.list_all_databases : [query.db_name]

      query.servers.each do |server|
        server.vm.sshable.cmd("common/bin/daemonizer 'lantern/bin/doctor/run_query' #{query.task_name}", stdin: JSON.generate({query: {is_system: query.is_system?, response_type: query.response_type, name: query.name, sql: query.sql&.tr("\n", " "), fn_label: query.fn_label, query_user: query.user}, server_type: server.primary? ? "primary" : "standby", dbs: dbs}))
      end
    end

    hop_wait_queries
  end

  label def wait_queries
    lantern_doctor.queries.each do |query|
      query.servers.each do |server|
        vm = server.vm
        status = "Unknown"
        begin
          status = vm.sshable.cmd("common/bin/daemonizer --check #{query.task_name}")
        rescue
        end

        case status
        when "Failed", "Succeeded"
          logs = JSON.parse(vm.sshable.cmd("common/bin/daemonizer --logs #{query.task_name}"))
          all_output = []

          if status == "Failed" && logs["stderr"].chomp == "update_needed"
            is_updating = server.strand.label == "wait_update_rhizome"
            will_update = !Semaphore.where(strand_id: server.strand.id, name: "update_rhizome").first.nil?
            if !is_updating && !will_update
              server.incr_update_rhizome
            end

            vm.sshable.cmd("common/bin/daemonizer --clean #{query.task_name}")
            next
          end

          if !logs["stdout"].empty?
            # stdout will be [{ "db": string, "result": string, "success": bool }]
            begin
              all_output = JSON.parse(logs["stdout"])
            rescue
            end
          end

          if status == "Failed"
            all_output = [{"db" => "*", "result" => logs["stdout"][..200], "err" => logs["stderr"], "success" => false}] + all_output.select { _1["success"] }
          else
            # resolve errored page if exists
            query.update_page_status("*", vm.name, true, nil, nil)
          end

          condition = "healthy"
          all_output.each do |output|
            if !output["success"]
              condition = "failed"
            end

            query.update_page_status(output["db"], vm.name, output["success"], output["result"], output["err"])
          end

          query.update(condition: condition, last_checked: Time.new)
          vm.sshable.cmd("common/bin/daemonizer --clean #{query.task_name}")
        end
      end
    end

    hop_wait
  end

  label def sync_system_queries
    decr_sync_system_queries
    lantern_doctor.sync_system_queries
    hop_wait
  end

  label def destroy
    decr_destroy

    lantern_doctor.failed_queries.each {
      _1.new_and_active_pages.each { |pg| pg.resolve }
    }

    lantern_doctor.destroy
    pop "lantern doctor is deleted"
  end
end
