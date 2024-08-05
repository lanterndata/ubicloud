# frozen_string_literal: true

require "forwardable"
require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

class Prog::GcpVm::Nexus < Prog::Base
  subject_is :gcp_vm

  extend Forwardable
  def_delegators :gcp_vm

  semaphore :destroy, :start_vm, :stop_vm, :update_storage, :update_size, :resize_data_disk

  def self.assemble(public_key, project_id, name: nil, size: "n1-standard-2",
    unix_user: "lantern", location: "us-central1", boot_image: Config.gcp_default_image,
    storage_size_gib: nil, arch: "x64", labels: {})

    unless (project = Project[project_id])
      fail "No existing project"
    end

    Validation.validate_location(location, project.provider)
    vm_size = Validation.validate_vm_size(size)

    ubid = GcpVm.generate_ubid
    name ||= GcpVm.ubid_to_name(ubid)

    Validation.validate_name(name)
    Validation.validate_os_user_name(unix_user)

    DB.transaction do
      cores = vm_size.vcpu
      vm = GcpVm.create(name: name, public_key: public_key, unix_user: unix_user,
        family: vm_size.family, cores: cores, location: location,
        boot_image: boot_image, arch: arch, storage_size_gib: storage_size_gib) { _1.id = ubid.to_uuid }

      vm.associate_with_project(project)

      Strand.create(
        prog: "GcpVm::Nexus",
        label: "start",
        stack: [{labels: labels}]
      ) { _1.id = vm.id }
    end
  end

  def self.assemble_with_sshable(unix_user, *, **kwargs)
    ssh_key = SshKey.generate
    kwargs[:unix_user] = unix_user
    st = assemble(ssh_key.public_key, *, **kwargs)
    Sshable.create(unix_user: unix_user, host: "temp_#{st.id}", raw_private_key_1: ssh_key.keypair) {
      _1.id = st.id
    }
    st
  end

  def host
    @host ||= gcp_vm.host
  end

  label def wait_ipv4
    gcp_client = Hosting::GcpApis.new
    addr_info = gcp_client.get_static_ipv4(gcp_vm.address_name, gcp_vm.location)
    if addr_info["status"] == "RESERVED"
      gcp_client.delete_ephermal_ipv4(gcp_vm.name, "#{gcp_vm.location}-a")
      gcp_client.assign_static_ipv4(gcp_vm.name, addr_info["address"], "#{gcp_vm.location}-a")
      gcp_vm.update(has_static_ipv4: true)
      gcp_vm.sshable.update(host: addr_info["address"])
      hop_add_to_external_index_fw
    end
    nap 10
  end

  label def add_to_external_index_fw
    gcp_client = Hosting::GcpApis.new
    if Config.lantern_external_index_fw_name
      gcp_client.add_ip_to_firewall(Config.lantern_external_index_fw_name, gcp_vm.sshable.host)
    end

    hop_wait_sshable
  end

  label def wait_create_vm
    gcp_vm.set_failed_on_deadline
    gcp_client = Hosting::GcpApis.new
    vm = gcp_client.get_vm(gcp_vm.name, "#{gcp_vm.location}-a")
    if vm["status"] == "RUNNING"
      address_name = "#{gcp_vm.name}-addr"
      gcp_client.create_static_ipv4(address_name, gcp_vm.location)
      gcp_vm.update(address_name: address_name)
      register_deadline(:wait, 5 * 60)
      hop_wait_ipv4
    else
      nap 10
    end
  end

  label def start
    register_deadline(:wait, 10 * 60)
    hop_create_vm
  end

  label def create_vm
    gcp_vm.set_failed_on_deadline
    gcp_client = Hosting::GcpApis.new
    labels = frame["labels"]
    gcp_client.create_vm(gcp_vm.name, "#{gcp_vm.location}-a", gcp_vm.boot_image, gcp_vm.public_key, gcp_vm.unix_user, "#{gcp_vm.family}-#{gcp_vm.cores}", gcp_vm.storage_size_gib, labels: labels)

    # remove labels from stack
    current_frame = strand.stack.first
    current_frame.delete("labels")
    strand.modified!(:stack)
    strand.save_changes

    hop_wait_create_vm
  end

  label def wait_sshable
    addr = gcp_vm.sshable.host

    # Alas, our hosting environment, for now, doesn't support IPv6, so
    # only check SSH availability when IPv4 is available: a
    # unistacked IPv6 server will not be checked.
    #
    # I considered removing wait_sshable altogether, but (very)
    # occasionally helps us glean interesting information about boot
    # problems.

    begin
      Socket.tcp(addr.to_s, 22, connect_timeout: 1) {}
    rescue SystemCallError
      nap 1
    end

    gcp_vm.update(display_state: "running")
    hop_wait
  end

  label def wait
    when_stop_vm_set? do
      register_deadline(:wait, 5 * 60)
      gcp_vm.update(display_state: "stopping")
      hop_stop_vm
    end

    when_start_vm_set? do
      register_deadline(:wait, 5 * 60)
      gcp_vm.update(display_state: "starting")
      hop_start_vm
    end

    when_destroy_set? do
      gcp_vm.update(display_state: "deleting")
      hop_destroy
    end

    when_update_size_set? do
      register_deadline(:wait, 5 * 60)
      gcp_vm.update(display_state: "updating")
      hop_update_size
    end

    when_update_storage_set? do
      register_deadline(:wait, 5 * 60)
      gcp_vm.update(display_state: "updating")
      hop_update_storage
    end

    when_resize_data_disk_set? do
      hop_resize_data_disk
    end

    nap 30
  end

  label def wait_vm_stopped
    if gcp_vm.is_stopped?
      gcp_vm.update(display_state: "stopped")
      hop_wait
    end
    nap 5
  end

  label def stop_vm
    gcp_client = Hosting::GcpApis.new
    gcp_client.stop_vm(gcp_vm.name, "#{gcp_vm.location}-a")

    decr_stop_vm

    hop_wait_vm_stopped
  end

  label def start_vm
    gcp_client = Hosting::GcpApis.new
    gcp_client.start_vm(gcp_vm.name, "#{gcp_vm.location}-a")

    decr_start_vm

    hop_wait_sshable
  end

  label def resize_data_disk
    decr_resize_data_disk
    gcp_vm.sshable.cmd("sudo resize2fs /dev/sdb")
    hop_wait
  end

  label def update_storage
    gcp_client = Hosting::GcpApis.new
    zone = "#{gcp_vm.location}-a"
    vm = gcp_client.get_vm(gcp_vm.name, zone)
    boot_disk = vm["disks"][0]
    data_disk = vm["disks"].find { !_1["boot"] }

    if data_disk.nil? && !gcp_vm.is_stopped?
      hop_stop_vm
    end

    decr_update_storage

    disk = data_disk || boot_disk
    gcp_client.resize_vm_disk(zone, disk["source"], gcp_vm.storage_size_gib)

    if data_disk
      incr_resize_data_disk
    end

    when_update_size_set? do
      hop_update_size
    end

    if gcp_vm.is_stopped?
      hop_start_vm
    end

    gcp_vm.update(display_state: "running")
    hop_wait
  end

  label def update_size
    if !gcp_vm.is_stopped?
      hop_stop_vm
    end
    decr_update_size
    gcp_client = Hosting::GcpApis.new
    gcp_client.update_vm_type(gcp_vm.name, "#{gcp_vm.location}-a", gcp_vm.display_size)

    when_update_storage_set? do
      register_deadline(:wait, 5 * 60)
      hop_update_storage
    end

    hop_start_vm
  end

  label def destroy
    DB.transaction do
      gcp_client = Hosting::GcpApis.new
      gcp_client.delete_vm(gcp_vm.name, "#{gcp_vm.location}-a")
      if gcp_vm.has_static_ipv4
        gcp_client.release_ipv4(gcp_vm.address_name, gcp_vm.location)
      end

      if Config.lantern_external_index_fw_name
        gcp_client.remove_ip_from_firewall(Config.lantern_external_index_fw_name, gcp_vm.sshable.host)
      end

      strand.children.each { _1.destroy }
      gcp_vm.projects.map { gcp_vm.dissociate_with_project(_1) }
      LanternDoctorPage.where(vm_name: gcp_vm.name).each { _1.resolve }
      gcp_vm.destroy
    end
    pop "gcp vm deleted"
  end
end
