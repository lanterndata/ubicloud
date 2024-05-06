# frozen_string_literal: true

require "parse-cron"
require_relative "../../model"
require_relative "../../db"

class LanternDoctorQuery < Sequel::Model
  one_to_one :strand, key: :id
  many_to_one :doctor, class: LanternDoctor, key: :doctor_id, primary_key: :id
  many_to_one :parent, class: self, key: :parent_id
  one_to_many :children, key: :parent_id, class: self

  plugin :association_dependencies, children: :destroy

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

  def should_run?
    CronParser.new(schedule).next(last_checked || Time.new - 61) <= Time.new
  end

  def is_system?
    !parent.nil?
  end

  def user
    return "postgres" if is_system?
    doctor.resource.db_user
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

      failed = false
      begin
        if is_system? && fn_label && LanternDoctorQuery.method_defined?(fn_label)
          res = send(fn_label, db, query_user)
        elsif sql
          res = lantern_server.run_query(sql, db: db, user: query_user).strip
        else
          fail "BUG: non-system query without sql"
        end

        if res != "f"
          failed = true
          any_failed = true
        end
      rescue => e
        failed = true
        any_failed = true
        Clog.emit("LanternDoctorQuery failed") { {error: e, query_name: name, db: db, resource_name: doctor.resource.name} }
        err_msg = e.message
      end

      pg = Page.from_tag_parts("LanternDoctorQueryFailed", id, db)

      if failed && !pg
        Prog::PageNexus.assemble_with_logs("Healthcheck: #{name} failed on #{doctor.resource.name} (#{db})", [ubid, doctor.ubid, lantern_server.ubid], {"stderr" => err_msg}, severity, "LanternDoctorQueryFailed", id, db)
      elsif !failed && pg
        pg.incr_resolve
      end
    end

    update(condition: any_failed ? "failed" : "healthy", last_checked: Time.new)
  end

  def check_daemon_embedding_jobs(db, query_user)
    if !LanternBackend.db
      fail "No connection to lantern backend database specified"
    end

    jobs = LanternBackend.db
      .select(:schema, :table, :src_column, :dst_column)
      .from(:embedding_generation_jobs)
      .where(database_id: doctor.resource.name)
      .where(Sequel.like(:db_connection, "%/#{db}"))
      .where(Sequel.lit('init_finished_at IS NOT NULL'))
      .all

    if jobs.empty?
      return "f"
    end

    lantern_server = doctor.resource.representative_server
    failed = jobs.any? do |job|
      res = lantern_server.run_query("SELECT (SELECT COUNT(*) FROM \"#{job[:schema]}\".\"#{job[:table]}\" WHERE \"#{job[:src_column]}\" IS NOT NULL AND \"#{job[:src_column]}\" != '' AND \"#{job[:dst_column]}\" IS NULL) > 1000", db: db, user: query_user).strip
      res == "t"
    end

    failed ? "t" : "f"
  end
end
