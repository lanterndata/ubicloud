# frozen_string_literal: true

require "google/cloud/compute/v1"
require_relative "../../config"
class Hosting::GcpApis
  def initialize()
    @project = Config.gcp_project_id

    unless (@project)
      fail "Please set GCP_PROJECT_ID env variable"
    end
  end

  def create_vm(name, region, image, ssh_key, user, machine_type, disk_size_gb)
    client = ::Google::Cloud::Compute::V1::Instances::Rest::Client.new
    zone = "#{region}-a"

    begin
      instance = client.get({ project: @project, zone: zone, instance: name })
      Clog.emit("gcp instance already exists") {{ name: name }}
      return instance
    rescue ::Google::Cloud::NotFoundError => e
      Clog.emit("creating gcp instance")
    end

    instance = {
      name: name,
      can_ip_forward: false,
      confidential_instance_config: {
        enable_confidential_compute: false
      },
      deletion_protection: false,
      description: '',
      disks: [
        {
          auto_delete: true,
          boot: true,
          device_name: "#{name}-boot",
          initialize_params: {
            disk_size_gb: disk_size_gb,
            disk_type: "projects/#{@project}/zones/#{zone}/diskTypes/pd-ssd",
            source_image: "projects/ubuntu-os-cloud/global/images/#{image}"
          },
          mode: 'READ_WRITE',
          type: 'PERSISTENT'
        }
      ],
      display_device: {
        enable_display: false
      },
      key_revocation_action_type: 'NONE',
      labels: {
        'goog-ec-src': 'vm_add-rest'
      },
      machine_type: "projects/#{@project}/zones/#{zone}/machineTypes/#{machine_type}",
      metadata: {
        items: [
          {
            key: 'ssh-keys',
            value: "#{user}:#{ssh_key} #{user}@lantern.dev"
          }
        ]
      },
      # Set network interfaces
      network_interfaces: [
        {
          access_configs: [
            {
              name: 'External NAT',
              network_tier: 'PREMIUM'
            }
          ],
          stack_type: 'IPV4_ONLY',
          subnetwork: "projects/#{@project}/regions/#{region}/subnetworks/default"
        }
      ],
      reservation_affinity: {
        consume_reservation_type: 'ANY_RESERVATION'
      },
      scheduling: {
        automatic_restart: true,
        on_host_maintenance: 'MIGRATE',
        provisioning_model: 'STANDARD'
      },
      service_accounts: [
        {
          email: '511682212298-compute@developer.gserviceaccount.com',
          scopes: [
            'https://www.googleapis.com/auth/devstorage.read_only',
            'https://www.googleapis.com/auth/logging.write',
            'https://www.googleapis.com/auth/monitoring.write',
            'https://www.googleapis.com/auth/servicecontrol',
            'https://www.googleapis.com/auth/service.management.readonly',
            'https://www.googleapis.com/auth/trace.append'
          ]
        }
      ],
      tags: {
        items: [
          "pg"
        ]
      },
      "zone": "projects/#{@project}/zones/#{zone}"
    }
    op = client.insert({ project: @project, zone: zone, instance_resource: instance })
    op.wait_until_done!
    instance = client.get({ project: @project, zone: zone, instance: name })
    instance.to_h
  end

  def create_static_ip4(vm_name, region)
    zone = "#{region}-a"
    addresses_client =  Google::Cloud::Compute::V1::Addresses::Rest::Client::new
    address_name = "#{vm_name}-addr"

    begin
      Clog.emit("calling get address") {{ address_name: address_name }}
      addr = addresses_client.get({ project: @project, region: region, address: address_name })
      Clog.emit("gcp static ip4 already exists") {{ address_name: address_name }}
      return addr.to_h[:address]
    rescue ::Google::Cloud::NotFoundError => e
      Clog.emit("creating gcp static ipv4")
    end

    op = addresses_client.insert({ address_resource: { name: address_name, network_tier: "PREMIUM", region: "projects/#{@project}/regions/#{region}" }, "project": @project, "region": region })
    op.wait_until_done!
    addr = addresses_client.get({ address: address_name, project: @project, "region": region })
    Clog.emit("Addr is::::::::::::::::::::::; ") {{ addr: addr }}
    addr = addr.to_h[:address]
    Clog.emit("Address is::::::::::::::::::::::; ") {{ addr: addr }}

    instances_client = ::Google::Cloud::Compute::V1::Instances::Rest::Client.new

    op = instances_client.delete_access_config({ project: @project, zone: zone, instance: vm_name, network_interface: "nic0", access_config: "External NAT" })
    op.wait_until_done!

    op = instances_client.add_access_config({
      access_config_resource: {
        name: "External NAT",
        nat_i_p: addr,
        network_tier: "PREMIUM",
        type: "ONE_TO_ONE_NAT"
      },
      project: @project,
      zone: zone,
      network_interface: "nic0",
      instance: vm_name
    })

    op.wait_until_done!

    addr
  end

  def delete_vm(vm_name, region)
    zone = "#{region}-a"
    instances_client = ::Google::Cloud::Compute::V1::Instances::Rest::Client.new
    op = instances_client.delete({ project: @project, instance: vm_name, zone: zone })
    op.wait_until_done
  end

  def start_vm(vm_name, region)
    zone = "#{region}-a"
    instances_client = ::Google::Cloud::Compute::V1::Instances::Rest::Client.new
    op = instances_client.start({ project: @project, instance: vm_name, zone: zone })
    op.wait_until_done
  end

  def stop_vm(vm_name, region)
    zone = "#{region}-a"
    instances_client = ::Google::Cloud::Compute::V1::Instances::Rest::Client.new
    op = instances_client.stop({ project: @project, instance: vm_name, zone: zone })
    op.wait_until_done
  end

end
