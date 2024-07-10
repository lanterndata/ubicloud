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

  def task_name
    "healthcheck_#{ubid}"
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

  def server_type
    parent&.server_type || super
  end

  def servers
    doctor.resource.servers.select { (server_type == "*") || (server_type == "primary" && _1.primary?) || (server_type == "standby" && _1.standby?) }
  end

  def should_run?
    is_scheduled_time = CronParser.new(schedule).next(last_checked || Time.new - 365 * 24 * 60 * 60) <= Time.new
    is_scheduled_time && doctor.resource.representative_server.vm.sshable.cmd("common/bin/daemonizer --check #{task_name}") == "NotStarted"
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

  def update_page_status(db, vm_name, success, output, err_msg)
    pg = LanternDoctorPage.where(query_id: id, db: db, vm_name: vm_name).where(Sequel.lit("status != 'resolved' ")).first
    if !success && !pg
      LanternDoctorPage.create_incident(self, db, vm_name, err: err_msg, output: output)
    elsif success && pg
      pg.resolve
    end
  end
end
