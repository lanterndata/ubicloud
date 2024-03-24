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

  semaphore :initial_provisioning, :update_superuser_password, :checkup
  semaphore :restart, :configure, :take_over, :destroy

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/lantern/#{instance_id}"
  end

  def path
    "/location/#{gcp_vm.location}/lantern/#{instance_id}"
  end

  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def connection_string
    return nil unless (hn = hostname)
    URI::Generic.build2(
      scheme: "postgres",
      userinfo: "postgres:#{URI.encode_uri_component(postgres_password)}",
      host: gcp_vm.domain || gcp_vm.sshable.host
    ).to_s
  end

  def run_query(query)
    gcp_vm.sshable.cmd("sudo lantern/bin/exec 'psql -U postgres #{query}'").chomp
  end
end
