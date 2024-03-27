# frozen_string_literal: true

require "googleauth"
require_relative "../../config"
class Hosting::GcpApis
  def initialize
    @project = Config.gcp_project_id

    unless @project
      fail "Please set GCP_PROJECT_ID env variable"
    end

    scopes = ['https://www.googleapis.com/auth/cloud-platform', 'https://www.googleapis.com/auth/compute']
    begin
     @authorization = Google::Auth.get_application_default(scopes)
    rescue => e
      Clog.emit("Error while doing google auth") {{ error: e }}
      fail "Google Auth failed, try setting 'GOOGLE_APPLICATION_CREDENTIALS' env varialbe"
    end

    @host = {
      :connection_string => "https://compute.googleapis.com",
      :headers => @authorization.apply({ :"Content-Type" => "application/json" })
    }
  end

  def get_region_from_zone(zone)
    zone[..-3]
  end

  def create_vm(name, zone, image, ssh_key, user, machine_type, disk_size_gb)
    region = get_region_from_zone(zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    instance = {
      name: name,
      canIpForward: false,
      confidentialInstanceConfig: {
        enableConfidentialCompute: false
      },
      deletionProtection: false,
      description: '',
      disks: [
        {
          autoDelete: true,
          boot: true,
          deviceName: "#{name}-boot",
          initializeParams: {
            diskSizeGb: disk_size_gb,
            diskType: "projects/#{@project}/zones/#{zone}/diskTypes/pd-ssd",
            sourceImage: "projects/ubuntu-os-cloud/global/images/#{image}"
          },
          mode: 'READ_WRITE',
          type: 'PERSISTENT'
        }
      ],
      displayDevice: {
        enableDisplay: false
      },
      keyRevocationActionType: 'NONE',
      labels: {
        'lantern-self-hosted': '1'
      },
      machineType: "projects/#{@project}/zones/#{zone}/machineTypes/#{machine_type}",
      metadata: {
        items: [
          {
            key: 'ssh-keys',
            value: "#{user}:#{ssh_key} #{user}@lantern.dev"
          }
        ]
      },
      # Set network interfaces
      networkInterfaces: [
        {
          accessConfigs: [
            {
              name: 'External NAT',
              networkTier: 'PREMIUM'
            }
          ],
          stackType: 'IPV4_ONLY',
          subnetwork: "projects/#{@project}/regions/#{region}/subnetworks/default"
        }
      ],
      reservationAffinity: {
        consumeReservationType: 'ANY_RESERVATION'
      },
      scheduling: {
        automaticRestart: true,
        onHostMaintenance: 'MIGRATE',
        provisioningModel: 'STANDARD'
      },
      serviceAccounts: [
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
      zone: "projects/#{@project}/zones/#{zone}"
    }

    connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances", body: JSON.dump(instance), expects: [200, 400])

  end

  def get_vm(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    response = connection.get(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}", expects: 200)

    JSON.parse(response.body)
  end

  def create_static_ipv4(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    address_name = "#{vm_name}-addr"
    body = {
      "name": address_name,
      "networkTier": "PREMIUM",
      "region": "projects/#{@project}/regions/#{region}"
    }
    connection.post(path: "/compute/v1/projects/#{@project}/regions/#{region}/addresses", body: JSON.dump(body), expects: 200)
  end

  def get_static_ipv4(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    address_name = "#{vm_name}-addr"
    response = connection.get(path: "/compute/v1/projects/#{@project}/regions/#{region}/addresses/#{address_name}", expects: 200)
    JSON.parse(response.body)
  end

  def delete_ephermal_ipv4(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    query = { accessConfig: "External NAT", networkInterface: "nic0" }
    connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/deleteAccessConfig", query: query, expects: [200,404])
  end

  def assign_static_ipv4(vm_name, addr, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    region = get_region_from_zone(zone)
    query = { networkInterface: "nic0" }

    body = {
        name: "External NAT",
        natIP: addr,
        networkTier: "PREMIUM",
        type: "ONE_TO_ONE_NAT"
    }

    connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/addAccessConfig", body: JSON.dump(body), query: query, expects: 200)
  end

  def release_ipv4(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    address_name = "#{vm_name}-addr"
    connection.delete(path: "/compute/v1/projects/#{@project}/regions/#{region}/addresses/#{address_name}", expects: [200, 404])
  end

  def delete_vm(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    connection.get(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}", expects: [200, 404])
  end

  def start_vm(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/start", expects: 200)
  end

  def stop_vm(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/stop", expects: 200)
  end
end
