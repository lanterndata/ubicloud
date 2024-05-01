# frozen_string_literal: true

require "googleauth"
require "excon"
require_relative "../../config"

class Hosting::GcpApis
  def initialize
    @project = Config.gcp_project_id

    unless @project
      fail "Please set GCP_PROJECT_ID env variable"
    end

    scopes = ["https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/compute"]
    begin
      @authorization = Google::Auth.get_application_default(scopes)
    rescue => e
      Clog.emit("Error while doing google auth") { {error: e} }
      fail "Google Auth failed, try setting 'GOOGLE_APPLICATION_CREDENTIALS' env varialbe"
    end

    @host = {
      connection_string: "https://compute.googleapis.com",
      headers: @authorization.apply({"Content-Type": "application/json"})
    }
  end

  def self.check_errors(response)
    body = JSON.parse(response.body)

    errors = body.fetch("error", {}).fetch("errors", [])
    if errors.size > 0
      Clog.emit("Error received from GCP APIs") { {body: body} }
      fail errors[0]["message"]
    end
  end

  def wait_for_operation(zone, operation)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])

    loop do
      response = connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/operations/#{operation}/wait", expects: [200])
      body = JSON.parse(response.body)
      break unless body["status"] != "DONE"
    rescue Excon::Error::Timeout
    end
  end

  def get_region_from_zone(zone)
    zone[..-3]
  end

  def create_vm(name, zone, image, ssh_key, user, machine_type, disk_size_gb, labels: {})
    region = get_region_from_zone(zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    instance = {
      name: name,
      canIpForward: false,
      confidentialInstanceConfig: {
        enableConfidentialCompute: false
      },
      deletionProtection: false,
      description: "",
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
          mode: "READ_WRITE",
          type: "PERSISTENT"
        }
      ],
      displayDevice: {
        enableDisplay: false
      },
      keyRevocationActionType: "NONE",
      labels: {
        "lantern-self-hosted": "1"
      }.merge(labels),
      machineType: "projects/#{@project}/zones/#{zone}/machineTypes/#{machine_type}",
      metadata: {
        items: [
          {
            key: "ssh-keys",
            value: "#{user}:#{ssh_key} #{user}@lantern.dev"
          }
        ]
      },
      # Set network interfaces
      networkInterfaces: [
        {
          accessConfigs: [
            {
              name: "External NAT",
              networkTier: "PREMIUM"
            }
          ],
          stackType: "IPV4_ONLY",
          subnetwork: "projects/#{@project}/regions/#{region}/subnetworks/default"
        }
      ],
      reservationAffinity: {
        consumeReservationType: "ANY_RESERVATION"
      },
      scheduling: {
        automaticRestart: true,
        onHostMaintenance: "MIGRATE",
        provisioningModel: "STANDARD"
      },
      serviceAccounts: [
        {
          email: Config.gcp_compute_service_account,
          scopes: [
            "https://www.googleapis.com/auth/devstorage.read_only",
            "https://www.googleapis.com/auth/logging.write",
            "https://www.googleapis.com/auth/monitoring.write",
            "https://www.googleapis.com/auth/servicecontrol",
            "https://www.googleapis.com/auth/service.management.readonly",
            "https://www.googleapis.com/auth/trace.append"
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

    response = connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances", body: JSON.dump(instance), expects: [200, 400])
    Hosting::GcpApis.check_errors(response)
  end

  def get_vm(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    response = connection.get(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}", expects: [200, 400, 404])
    Hosting::GcpApis.check_errors(response)

    JSON.parse(response.body)
  end

  def create_static_ipv4(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    address_name = "#{vm_name}-addr"
    body = {
      name: address_name,
      networkTier: "PREMIUM",
      region: "projects/#{@project}/regions/#{region}"
    }
    response = connection.post(path: "/compute/v1/projects/#{@project}/regions/#{region}/addresses", body: JSON.dump(body), expects: [200, 400])
    Hosting::GcpApis.check_errors(response)
  end

  def get_static_ipv4(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    address_name = "#{vm_name}-addr"
    response = connection.get(path: "/compute/v1/projects/#{@project}/regions/#{region}/addresses/#{address_name}", expects: 200)
    JSON.parse(response.body)
  end

  def delete_ephermal_ipv4(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    query = {accessConfig: "External NAT", networkInterface: "nic0"}
    response = connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/deleteAccessConfig", query: query, expects: [200, 400, 404])
    Hosting::GcpApis.check_errors(response)
    data = JSON.parse(response.body)
    wait_for_operation(zone, data["id"])
  end

  def assign_static_ipv4(vm_name, addr, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    query = {networkInterface: "nic0"}

    body = {
      name: "External NAT",
      natIP: addr,
      networkTier: "PREMIUM",
      type: "ONE_TO_ONE_NAT"
    }

    response = connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/addAccessConfig", body: JSON.dump(body), query: query, expects: [200, 400])
    Hosting::GcpApis.check_errors(response)
    data = JSON.parse(response.body)
    wait_for_operation(zone, data["id"])
  end

  def release_ipv4(vm_name, region)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    address_name = "#{vm_name}-addr"
    connection.delete(path: "/compute/v1/projects/#{@project}/regions/#{region}/addresses/#{address_name}", expects: [200, 404])
  end

  def delete_vm(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    connection.delete(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}", expects: [200, 404])
  end

  def start_vm(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    response = connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/start", expects: 200)
    Hosting::GcpApis.check_errors(response)
    data = JSON.parse(response.body)
    wait_for_operation(zone, data["id"])
  end

  def stop_vm(vm_name, zone)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    response = connection.post(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}/stop", expects: 200)
    data = JSON.parse(response.body)
    wait_for_operation(zone, data["id"])
  end

  def update_vm_type(vm_name, zone, machine_type)
    query = {mostDisruptiveAllowedAction: "NONE"}
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    vm = get_vm(vm_name, zone)
    vm["machineType"] = "projects/#{@project}/zones/#{zone}/machineTypes/#{machine_type}"
    response = connection.put(path: "/compute/v1/projects/#{@project}/zones/#{zone}/instances/#{vm_name}", body: JSON.dump(vm), query: query, expects: [200, 400])
    Hosting::GcpApis.check_errors(response)
  end

  def resize_vm_disk(zone, disk_source, storage_size_gib)
    connection = Excon.new(@host[:connection_string], headers: @host[:headers])
    body = {sizeGb: storage_size_gib.to_s}
    path = URI.parse(disk_source).path
    response = connection.post(path: "#{path}/resize", body: JSON.dump(body), expects: [200, 400])
    Hosting::GcpApis.check_errors(response)
    data = JSON.parse(response.body)
    wait_for_operation(zone, data["id"])
  end

  def list_objects(bucket, prefix)
    connection = Excon.new("https://storage.googleapis.com", headers: @host[:headers])
    query = {prefix: prefix}
    puts "Query is #{query}"
    response = connection.get(path: "/storage/v1/b/#{bucket}/o", query: query, expects: [200, 400])
    Hosting::GcpApis.check_errors(response)
    data = JSON.parse(response.body)

    if data["items"].nil?
      return []
    end

    data["items"].map { |hsh| {key: hsh["name"], last_modified: Time.new(hsh["updated"])} }
  end

  def get_json_object(bucket, object)
    connection = Excon.new("https://storage.googleapis.com", headers: @host[:headers])
    query = {alt: "media"}
    response = connection.get(path: "/storage/v1/b/#{bucket}/o/#{CGI.escape object}", query: query, expects: 200)

    begin
      JSON.parse(response.body)
    rescue => e
      Clog.emit("get_json_object: could not parse json body") { {bucket: bucket, key: object, error: e} }
      nil
    end
  end

  def create_service_account(name, description = "")
    connection = Excon.new("https://iam.googleapis.com", headers: @host[:headers])

    body = {
      accountId: name,
      serviceAccount: {
        displayName: name,
        description: description
      }
    }

    response = connection.post(path: "/v1/projects/#{@project}/serviceAccounts", body: JSON.dump(body), expects: [200, 400, 403])

    Hosting::GcpApis.check_errors(response)

    JSON.parse(response.body)
  end

  def remove_service_account(service_account_email)
    connection = Excon.new("https://iam.googleapis.com", headers: @host[:headers])

    response = connection.delete(path: "/v1/projects/#{@project}/serviceAccounts/#{service_account_email}", expects: [200, 400])
    Hosting::GcpApis.check_errors(response)
  end

  def export_service_account_key(service_account_email)
    connection = Excon.new("https://iam.googleapis.com", headers: @host[:headers])
    response = connection.post(path: "/v1/projects/#{@project}/serviceAccounts/#{service_account_email}/keys", body: JSON.dump({}), expects: [200, 400, 404, 403])
    Hosting::GcpApis.check_errors(response)
    data = JSON.parse(response.body)
    data["privateKeyData"]
  end

  def allow_bucket_usage_by_prefix(service_account_email, bucket_name, prefix)
    connection = Excon.new("https://storage.googleapis.com", headers: @host[:headers])
    response = connection.get(path: "/storage/v1/b/#{bucket_name}/iam", query: {"optionsRequestedPolicyVersion" => 3}, expects: [200, 400, 403])

    Hosting::GcpApis.check_errors(response)

    policy = JSON.parse(response.body)

    policy["bindings"] += [
      {
        role: "roles/storage.objectAdmin",
        members: ["serviceAccount:#{service_account_email}"],
        condition: {
          expression: "resource.name.startsWith(\"projects/_/buckets/#{bucket_name}/objects/#{prefix}\")",
          title: "Access backups for path #{prefix}"
        }
      },
      {
        # This role should be created manually
        # It should only have storage.objects.list policy attached
        role: "projects/#{@project}/roles/storage.objectList",
        members: ["serviceAccount:#{service_account_email}"]
      }
    ]
    policy["version"] = 3

    response = connection.put(path: "/storage/v1/b/#{bucket_name}/iam", body: JSON.dump(policy), expects: [200, 400, 403])

    Hosting::GcpApis.check_errors(response)
  end
end
