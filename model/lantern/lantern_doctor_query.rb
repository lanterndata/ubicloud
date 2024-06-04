# frozen_string_literal: true

require "parse-cron"
require_relative "../../model"
require_relative "../../db"

class LanternDoctorQuery < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :doctor, class: LanternDoctor, key: :doctor_id, primary_key: :id
  many_to_one :parent, class: self, key: :parent_id
  one_to_many :children, key: :parent_id, class: self
  one_to_many :pages, key: :query_id, primary_key: :id, class: LanternDoctorPage

  plugin :association_dependencies, children: :destroy, pages: :destroy
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods

  semaphore :destroy

  def sql
    parent&.sql || super
  end

  def name
    parent&.name || super
  end

  def db_name
    parent&.db_name || super
  end

  def severity
    parent&.severity || super
  end

  def schedule
    parent&.schedule || super
  end

  def fn_label
    parent&.fn_label || super
  end

  def response_type
    parent&.response_type || super
  end

  def should_run?
    CronParser.new(schedule).next(last_checked || Time.new - 365 * 24 * 60 * 60) <= Time.new
  end

  def is_system?
    !parent.nil?
  end

  def user
    return "postgres" if is_system?
    doctor.resource.db_user
  end

  def active_pages
    LanternDoctorPage.where(query_id: id, status: ["triggered", "acknowledged"]).all
  end

  def new_and_active_pages
    LanternDoctorPage.where(query_id: id, status: ["new", "triggered", "acknowledged"]).all
  end

  def run
    if !should_run?
      return nil
    end

    lantern_server = doctor.resource.representative_server
    dbs = (db_name == "*") ? lantern_server.list_all_databases : [db_name]
    query_user = user

    any_failed = false
    dbs.each do |db|
      err_msg = ""
      output = ""

      failed = false
      begin
        if is_system? && fn_label && LanternDoctorQuery.method_defined?(fn_label)
          res = send(fn_label, db, query_user)
        elsif sql
          res = lantern_server.run_query(sql, db: db, user: query_user).strip
        else
          fail "BUG: non-system query without sql"
        end

        case response_type
        when "bool"
          if res != "f"
            failed = true
            any_failed = true
          end
        when "rows"
          if res != ""
            failed = true
            any_failed = true
          end
          output = res
        else
          fail "BUG: invalid response type (#{response_type}) on query #{name}"
        end
      rescue => e
        failed = true
        any_failed = true
        Clog.emit("LanternDoctorQuery failed") { {error: e, query_name: name, db: db, resource_name: doctor.resource.name} }
        err_msg = e.message
      end

      pg = LanternDoctorPage.where(query_id: id, db: db).where(Sequel.lit("status != 'resolved' ")).first

      if failed && !pg
        LanternDoctorPage.create_incident(self, db, err: err_msg, output: output)
      elsif !failed && pg
        pg.resolve
      end
    end

    update(condition: any_failed ? "failed" : "healthy", last_checked: Time.new)
  end

  def check_daemon_embedding_jobs(db, query_user)
    lantern_server = doctor.resource.representative_server
    jobs_table_exists = lantern_server.run_query(<<SQL).chomp.strip
      SELECT EXISTS (
       SELECT FROM pg_catalog.pg_class c
       JOIN   pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE  n.nspname = '_lantern_internal'
       AND    c.relname = 'embedding_generation_jobs'
       AND    c.relkind = 'r'
     );
SQL

    if jobs_table_exists == "f"
      return "f"
    end

    jobs = lantern_server.run_query("SELECT \"schema\", \"table\", src_column, dst_column FROM _lantern_internal.embedding_generation_jobs WHERE init_finished_at IS NOT NULL AND canceled_at IS NULL;")

    jobs = jobs.chomp.strip.split("\n").map do |row|
      values = row.split(",")
      {schema: values[0], table: values[1], src_column: values[2], dst_column: values[3]}
    end

    if jobs.empty?
      return "f"
    end

    failed = jobs.any? do |job|
      res = lantern_server.run_query("SELECT (SELECT COUNT(*) FROM \"#{job[:schema]}\".\"#{job[:table]}\" WHERE \"#{job[:src_column]}\" IS NOT NULL AND \"#{job[:src_column]}\" != '' AND \"#{job[:src_column]}\" != 'Error: Summary failed (llm)' AND \"#{job[:dst_column]}\" IS NULL) > 2000", db: db, user: query_user).strip
      res == "t"
    end

    failed ? "t" : "f"
  end

  def check_disk_space_usage(_db, _query_user)
    output = ""
    doctor.resource.servers.each do |serv|
      usage_percent = serv.vm.sshable.cmd("df | awk '$1 == \"/dev/root\" {print $5}' | sed 's/%//'").strip.to_i
      if usage_percent > 90
        server_type = serv.primary? ? "primary" : "standby"
        output += "#{server_type} server - usage #{usage_percent}%\n"
      end
    end
    output.chomp
  end
end
