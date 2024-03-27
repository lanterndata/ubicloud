# frozen_string_literal: true

require "net/ssh"
require_relative "../../model"

class LanternServer < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :gcp_vm, key: :id, primary_key: :vm_id

  dataset_module Authorization::Dataset
  dataset_module Pagination

  include ResourceMethods
  include SemaphoreMethods
  include Authorization::HyperTagMethods
  include Authorization::TaggableMethods

  semaphore :initial_provisioning, :update_superuser_password, :update_lantern_extension, :update_extras_extension, :update_image, :setup_ssl, :add_domain, :update_rhizome, :checkup
  semaphore :restart, :configure, :take_over, :destroy

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/lantern/#{name}"
  end

  def path
    "/location/#{gcp_vm.location}/lantern/#{name}"
  end

  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def connection_string
    return nil unless (gcp_vm.sshable.host && !gcp_vm.sshable.host.start_with?("temp"))
    URI::Generic.build2(
      scheme: "postgres",
      userinfo: "postgres:#{URI.encode_uri_component(postgres_password)}",
      host: gcp_vm.domain || gcp_vm.sshable.host,
      port: 6432
    ).to_s
  end

  def run_query(query)
    gcp_vm.sshable.cmd("sudo lantern/bin/exec \"psql -U postgres -c '#{query}'\"").chomp
  end

  def display_state
    return "domain setup" if strand.label.include?("domain")
    return "ssl setup" if strand.label.include?("setup_ssl")
    return "updating" if strand.label.include?("update")
    return "running" if ["wait"].include?(strand.label)
    return "deleting" if destroy_set? || strand.label == "destroy"
    "creating"
  end
end
