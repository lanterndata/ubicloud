# frozen_string_literal: true

require_relative "../model"

class GcpVm < Sequel::Model
  one_to_one :strand, key: :id
  one_to_one :sshable, key: :id

  plugin :association_dependencies, sshable: :destroy

  dataset_module Pagination
  dataset_module Authorization::Dataset

  include ResourceMethods
  include SemaphoreMethods
  include DisplayStatusMethods
  semaphore :destroy, :start_vm, :stop_vm, :update_storage, :update_size

  include Authorization::HyperTagMethods

  def hyper_tag_name(project)
    "project/#{project.ubid}/location/#{location}/gcp_vm/#{name}"
  end

  include Authorization::TaggableMethods

  def path
    "/location/#{location}/gcp_vm/#{name}"
  end

  def host
    sshable&.host
  end

  def mem_gib_ratio
    return 3.2 if arch == "arm64"
    8
  end

  def mem_gib
    (cores * mem_gib_ratio).to_i
  end

  def display_size
    "#{family}-#{cores}"
  end

  # Various names in linux, like interface names, are obliged to be
  # short, so truncate the ubid. This does introduce the spectre of
  # collisions.  When the time comes, we'll have to ensure it doesn't
  # happen on a single host, pushing into the allocation process.
  def self.ubid_to_name(id)
    id.to_s[0..7]
  end

  def inhost_name
    self.class.ubid_to_name(UBID.from_uuidish(id))
  end

  def is_stopped?
    gcp_client = Hosting::GcpApis.new
    vm = gcp_client.get_vm(name, "#{location}-a")
    vm["status"] == "TERMINATED"
  end

  def self.redacted_columns
    super + [:public_key]
  end

  def swap_ip(vm)
    # swap ips in gcp
    gcp_client = Hosting::GcpApis.new
    zone1 = "#{location}-a"
    zone2 = "#{vm.location}-a"
    gcp_client.delete_ephermal_ipv4(name, zone1)
    gcp_client.delete_ephermal_ipv4(vm.name, zone2)
    vm_info = gcp_client.get_vm(name, zone1)
    # we are explicitly checking if ip is already assigned
    # because the operation can be terminated while running
    # and on next retry we will have error that the external ip is already assigned
    if !vm_info["networkInterfaces"][0]["accessConfigs"].find { _1["natIP"] == vm.sshable.host }
      gcp_client.assign_static_ipv4(name, vm.sshable.host, zone1)
    end
    vm_info = gcp_client.get_vm(vm.name, zone2)
    if !vm_info["networkInterfaces"][0]["accessConfigs"].find { _1["natIP"] == sshable.host }
      gcp_client.assign_static_ipv4(vm.name, sshable.host, zone2)
    end

    # update sshable hosts
    current_host = sshable.host
    new_host = vm.sshable.host
    sshable.update(host: "temp_#{name}")
    vm.sshable.update(host: current_host)
    sshable.update(host: new_host)
    current_address_name = address_name

    # update address names
    update(address_name: vm.address_name)
    vm.update(address_name: current_address_name)

    sshable.invalidate_cache_entry
    vm.sshable.invalidate_cache_entry
  end
end
