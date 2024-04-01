# frozen_string_literal: true

require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

require_relative "../../lib/hosting/gcp_apis"

class Prog::GcpVm::Nexus < Prog::Base
  subject_is :gcp_vm
  semaphore :destroy, :start_vm, :stop_vm

  def self.assemble(public_key, project_id, name: nil, size: "standard-2",
    unix_user: "lantern", location: "us-central1", boot_image: "ubuntu-2204-jammy-v20240319",
    storage_size_gib: nil, arch: "x64", domain: nil)

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
        boot_image: boot_image, arch: arch, storage_size_gib: storage_size_gib, domain: domain) { _1.id = ubid.to_uuid }

      vm.associate_with_project(project)

      Strand.create(
        prog: "GcpVm::Nexus",
        label: "start"
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
    gcp_client = Hosting::GcpApis::new
    addr_info = gcp_client.get_static_ipv4(gcp_vm.name, gcp_vm.location)
    if addr_info["status"] == "RESERVED"
      gcp_client.delete_ephermal_ipv4(gcp_vm.name, "#{gcp_vm.location}-a")
      gcp_client.assign_static_ipv4(gcp_vm.name, addr_info["address"], "#{gcp_vm.location}-a")
      gcp_vm.update(has_static_ipv4: true)
      gcp_vm.sshable.update(host: addr_info["address"])
      hop_wait_sshable
    end
    nap 10
  end

  label def wait_create_vm
    gcp_client = Hosting::GcpApis::new
    vm = gcp_client.get_vm(gcp_vm.name, "#{gcp_vm.location}-a")
    if vm["status"] == "RUNNING"
      gcp_client.create_static_ipv4(gcp_vm.name, gcp_vm.location)
      register_deadline(:wait, 5 * 60)
      hop_wait_ipv4
    else
      nap 10
    end
  end

  label def start
    gcp_client = Hosting::GcpApis::new
    gcp_client.create_vm(gcp_vm.name, "#{gcp_vm.location}-a", gcp_vm.boot_image, gcp_vm.public_key, gcp_vm.unix_user, "n1-#{gcp_vm.family}-#{gcp_vm.cores}", gcp_vm.storage_size_gib)
    register_deadline(:wait, 10 * 60)
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
      hop_stop_vm
    end

    when_start_vm_set? do
      register_deadline(:wait, 5 * 60)
      hop_start_vm
    end

    when_destroy_set? do
      hop_destroy
    end

    nap 30
  end

  label def stop_vm
    gcp_vm.update(display_state: "stopping")

    gcp_client = Hosting::GcpApis::new
    gcp_client.stop_vm(gcp_vm.name, "#{gcp_vm.location}-a")

    gcp_vm.update(display_state: "stopped")

    decr_stop_vm

    hop_wait
  end

  label def start_vm
    gcp_vm.update(display_state: "starting")

    gcp_client = Hosting::GcpApis::new
    gcp_client.start_vm(gcp_vm.name, "#{gcp_vm.location}-a")

    gcp_vm.update(display_state: "running")

    decr_start_vm

    hop_wait_sshable
  end

  label def destroy
    DB.transaction do
      gcp_vm.update(display_state: "deleting")
      gcp_client = Hosting::GcpApis::new
      gcp_client.delete_vm(gcp_vm.name, "#{gcp_vm.location}-a")
      if gcp_vm.has_static_ipv4
        gcp_client.release_ipv4(gcp_vm.name, gcp_vm.location)
      end
      strand.children.each { _1.destroy }
      gcp_vm.projects.map { gcp_vm.dissociate_with_project(_1) }
      gcp_vm.destroy
    end
    pop "gcp vm deleted"
  end
end
