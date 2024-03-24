# frozen_string_literal: true

require "netaddr"
require "json"
require "shellwords"
require "openssl"
require "base64"

require_relative "../../lib/hosting/gcp_apis"

# TODO
# 1. Add migration for gcp_vm
# 2. Add migration for lantern_server
# 3. Fix run_query for lantern_server
# 4. Add sidebar item for lantern_server
# 5. Add view and routes for lantern_server
# 6. Write tests for lantern_server

class Prog::GcpVm::Nexus < Prog::Base
  subject_is :gcp_vm
  semaphore :destroy, :start_after_host_reboot, :prevent_destroy, :update_firewall_rules

  def self.assemble(public_key, project_id, name: nil, size: "standard-2",
                    unix_user: "lantern", location: "us-central1", boot_image: "ubuntu-2204-jammy-v20240319",
                    storage_size_gib: nil, arch: "x64")

    unless (project = Project[project_id])
      Clog.emit("Project id") { {project_id: project_id} }
      fail "No existing project"
    end

    Validation.validate_location(location, project.provider)
    vm_size = Validation.validate_vm_size(size)


    ubid = GcpVm.generate_ubid
    name ||= GcpVm.ubid_to_name(ubid)

    Validation.validate_name(name)
    Validation.validate_os_user_name(unix_user)

    DB.transaction do
      cores = if arch == "arm64"
        vm_size.vcpu
      else
        vm_size.vcpu / 2
      end

      vm = GcpVm.create(name: name, public_key: public_key, unix_user: unix_user,
        family: vm_size.family, cores: cores, location: location,
        boot_image: boot_image, arch: arch, storage_size_gib: storage_size_gib) { _1.id = ubid.to_uuid }

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

  def vm_name
    @vm_name ||= vm.inhost_name
  end

  def q_vm
    vm_name.shellescape
  end

  def vm_home
    File.join("", "vm", vm_name)
  end

  def host
    @host ||= gcp_vm.vm_host
  end

  label def start
    # Call to GCP to create VM with info from vm
    # As VM is created Allocate Static IP for VM
    # As Soon as static ip is assigned create DNS record for that IP
    Clog.emit("Creating client") {{ name: gcp_vm.name, location: gcp_vm.location }}
    gcp_client = Hosting::GcpApis::new
    Clog.emit("Client created") {{ name: gcp_vm.name, location: gcp_vm.location }}

    DB.transaction do
      Clog.emit("Create GCP VM") {{ name: gcp_vm.name, location: gcp_vm.location }}
      gcp_response = gcp_client.create_vm(gcp_vm.name, gcp_vm.location, gcp_vm.boot_image, gcp_vm.public_key, gcp_vm.unix_user, "n1-#{gcp_vm.family}-#{gcp_vm.cores}", gcp_vm.storage_size_gib)
      Clog.emit("Created GCP VM") {{ name: gcp_vm.name, location: gcp_vm.location }}
    end

    Clog.emit("Getting ip4") {{ name: gcp_vm.name, location: gcp_vm.location }}
    ip4 = gcp_client.create_static_ip4(gcp_vm.name, gcp_vm.location)
    Clog.emit("IP4 GOT") {{ ip4: ip4 }}
    gcp_vm.sshable.update(host: ip4)
    # TODO:: Create DNS record
    register_deadline(:wait, 10 * 60)
    # We don't need storage_volume info anymore, so delete it before
    # transitioning to the next state.
    hop_wait_sshable
  end

  label def run
    gcp_client = Hosting::GcpApis::new
    # TODO
    # gcp_client.start_vm(gcp_vm.name, gcp_vm.location)
    hop_wait_sshable
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
    # hop_create_billing_record unless addr

    begin
      Clog.emit("Trying to ssh to addr") {{ addr: addr.to_s }}
      Socket.tcp(addr.to_s, 22, connect_timeout: 1) {}
    rescue SystemCallError
      nap 1
    end

    gcp_vm.update(display_state: "running")
    pop "running"
  end

  label def create_billing_record
    gcp_vm.update(display_state: "running")
    # Clog.emit("vm provisioned") { {vm: gcp_vm.values, provision: {vm_id: gcp_vm.id, duration: Time.now - gcp_vm.created_at}} }
    # project = gcp_vm.projects.first
    # hop_wait unless project.billable
    #
    # BillingRecord.create_with_id(
    #   project_id: project.id,
    #   resource_id: gcp_vm.id,
    #   resource_name: gcp_vm.name,
    #   billing_rate_id: BillingRate.from_resource_properties("VmCores", gcp_vm.family, gcp_vm.location)["id"],
    #   amount: gcp_vm.cores
    # )
    #
    # if gcp_vm.ip4_enabled
    #   BillingRecord.create_with_id(
    #     project_id: project.id,
    #     resource_id: gcp_vm.assigned_vm_address.id,
    #     resource_name: gcp_vm.assigned_vm_address.ip,
    #     billing_rate_id: BillingRate.from_resource_properties("IPAddress", "IPv4", gcp_vm.location)["id"],
    #     amount: 1
    #   )
    # end

    # hop_wait
  end

  label def wait
    when_start_after_host_reboot_set? do
      register_deadline(:wait, 5 * 60)
      hop_start_after_host_reboot
    end
    nap 30
  end

  label def start_after_host_reboot
    gcp_vm.update(display_state: "starting")

    gcp_client = Hosting::GcpApis::new
    gcp_client.start_vm(gcp_vm.name, gcp_vm.location)

    gcp_vm.update(display_state: "running")

    decr_start_after_host_reboot

    hop_wait
  end

  label def destroy
    gcp_client = Hosting::GcpApis::new
    gcp_client.delete_vm(gcp_vm.name, gcp_vm.location)
    pop "vm deleted"
  end
end
