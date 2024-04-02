# frozen_string_literal: true

require "time"
require "netaddr"

module Validation
  class ValidationFailed < CloverError
    def initialize(details)
      super(400, "Invalid request", "Validation failed for following fields: #{details.keys.join(", ")}", details)
    end
  end

  # Allow DNS compatible names
  # - Max length 63
  # - Only lowercase letters, numbers, and hyphens
  # - Not start or end with a hyphen
  # Adapted from https://stackoverflow.com/a/7933253
  # Do not allow uppercase letters to not deal with case sensitivity
  ALLOWED_NAME_PATTERN = '\A[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\z'

  # Different operating systems have different conventions.
  # Below are reasonable restrictions that works for most (all?) systems.
  # - Max length 32
  # - Only lowercase letters, numbers, hyphens and underscore
  # - Not start with a hyphen or number
  ALLOWED_OS_USER_NAME_PATTERN = '\A[a-z_][a-z0-9_-]{0,31}\z'

  # Minio user name, we are using ALLOWED_OS_USER_NAME_PATTERN with min length of 3
  ALLOWED_MINIO_USERNAME_PATTERN = '\A[a-z_][a-z0-9_-]{2,31}\z'

  ALLOWED_PORT_RANGE_PATTERN = '\A(\d+)(?:\.\.(\d+))?\z'

  ALLOWED_DOMAIN_PATTERN = '^\A((?!-)[a-z0-9-]{1,63}(?<!-)\.)+[a-z]{2,6}\z'

  def self.validate_name(name)
    msg = "Name must only contain lowercase letters, numbers, and hyphens and have max length 63."
    fail ValidationFailed.new({name: msg}) unless name&.match(ALLOWED_NAME_PATTERN)
  end

  def self.validate_minio_username(username)
    msg = "Minio user must only contain lowercase letters, numbers, hyphens and underscore and cannot start with a number or hyphen. It also have max length of 32, min length of 3."
    fail ValidationFailed.new({username: msg}) unless username&.match(ALLOWED_MINIO_USERNAME_PATTERN)
  end

  def self.validate_provider(provider)
    msg = "\"#{provider}\" is not a valid provider. Available providers: #{Option::Providers.keys}"
    fail ValidationFailed.new({provider: msg}) unless Option::Providers.key?(provider)
  end

  def self.validate_location(location, provider = nil)
    available_locs = Option.locations_for_provider(provider, only_visible: false).map(&:name)
    msg = "\"#{location}\" is not a valid location for provider \"#{provider}\". Available locations: #{available_locs}"
    fail ValidationFailed.new({provider: msg}) unless available_locs.include?(location)
  end

  def self.validate_vm_size(size)
    unless (vm_size = Option::VmSizes.find { _1.name == size })
      fail ValidationFailed.new({size: "\"#{size}\" is not a valid virtual machine size. Available sizes: #{Option::VmSizes.map(&:name)}"})
    end
    vm_size
  end

  # def self.validate_postgres_ha_type(ha_type)
  #   unless Option::PostgresHaOptions.find { _1.name == ha_type }
  #     fail ValidationFailed.new({ha_type: "\"#{ha_type}\" is not a valid PostgreSQL high availability option. Available options: #{Option::PostgresHaOptions.map(&:name)}"})
  #   end
  # end

  def self.validate_os_user_name(os_user_name)
    msg = "OS user name must only contain lowercase letters, numbers, hyphens and underscore and cannot start with a number or hyphen. It also have max length of 32."
    fail ValidationFailed.new({user: msg}) unless os_user_name&.match(ALLOWED_OS_USER_NAME_PATTERN)
  end

  def self.validate_org_id(org_id)
    msg = "org_id should be number"
    fail ValidationFailed.new({org_id: msg}) unless org_id.to_s.match? (/^\d+$/)
  end

  def self.validate_version(version, field_name)
    msg = "#{field_name} should not be empty"
    fail ValidationFailed.new({version: msg}) unless version && !version.to_s.strip.empty?
  end

  def self.validate_storage_volumes(storage_volumes, boot_disk_index)
    allowed_keys = [:encrypted, :size_gib, :boot, :skip_sync]
    fail ValidationFailed.new({storage_volumes: "At least one storage volume is required."}) if storage_volumes.empty?
    if boot_disk_index < 0 || boot_disk_index >= storage_volumes.length
      fail ValidationFailed.new({boot_disk_index: "Boot disk index must be between 0 and #{storage_volumes.length - 1}"})
    end
    storage_volumes.each { |volume|
      volume.each_key { |key|
        fail ValidationFailed.new({storage_volumes: "Invalid key: #{key}"}) unless allowed_keys.include?(key)
      }
    }
  end

  # def self.validate_postgres_size(size)
  #   unless (postgres_size = Option::PostgresSizes.find { _1.name == size })
  #     fail ValidationFailed.new({size: "\"#{size}\" is not a valid PostgreSQL database size. Available sizes: #{Option::PostgresSizes.map(&:name)}"})
  #   end
  #   postgres_size
  # end

  def self.validate_lantern_size(size)
    unless (postgres_size = Option::LanternSizes.find { _1.name == size })
      fail ValidationFailed.new({size: "\"#{size}\" is not a valid Lantern database size. Available sizes: #{Option::LanternSizes.map(&:name)}"})
    end
    postgres_size
  end

  def self.validate_date(date, param = "date")
    # I use DateTime.parse instead of Time.parse because it uses UTC as default
    # timezone but Time.parse uses local timezone
    DateTime.parse(date.to_s).to_time
  rescue ArgumentError
    msg = "\"#{date}\" is not a valid date for \"#{param}\"."
    fail ValidationFailed.new({param => msg})
  end

  def self.validate_lantern_storage_size(current_storage_size_gib, storage_size_gib)
    msg = "storage_size_gib can not be smaller than #{current_storage_size_gib}"
    fail ValidationFailed.new({storage_size_gib: msg}) unless current_storage_size_gib < storage_size_gib
  end

  def self.validate_postgres_superuser_password(original_password, repeat_password = nil)
    messages = []
    messages.push("Password must have 12 characters minimum.") if original_password.size < 12
    messages.push("Password must have at least one lowercase letter.") unless original_password.match?(/[a-z]/)
    messages.push("Password must have at least one uppercase letter.") unless original_password.match?(/[A-Z]/)
    messages.push("Password must have at least one digit.") unless original_password.match?(/[0-9]/)
    messages.push("Passwords must match.") if repeat_password && original_password != repeat_password

    unless messages.empty?
      if repeat_password
        fail ValidationFailed.new({"original_password" => messages.map { _1 }})
      else
        fail ValidationFailed.new({"password" => messages.map { _1 }})
      end
    end
  end

  def self.validate_cidr(cidr)
    NetAddr::IPv4Net.parse(cidr)
  rescue NetAddr::ValidationError
    fail ValidationFailed.new({CIDR: "Invalid CIDR"})
  end

  def self.validate_port_range(port_range)
    fail ValidationFailed.new({port_range: "Invalid port range"}) unless (match = port_range.match(ALLOWED_PORT_RANGE_PATTERN))
    start_port = match[1].to_i

    if match[2]
      end_port = match[2].to_i
      fail ValidationFailed.new({port_range: "Start port must be between 0 to 65535"}) unless (0..65535).cover?(start_port)
      fail ValidationFailed.new({port_range: "End port must be between 0 to 65535"}) unless (0..65535).cover?(end_port)
      fail ValidationFailed.new({port_range: "Start port must be smaller than or equal to end port"}) unless start_port <= end_port
    else
      fail ValidationFailed.new({port_range: "Port must be between 0 to 65535"}) unless (0..65535).cover?(start_port)
    end

    end_port ? [start_port, end_port] : [start_port]
  end

  def self.validate_domain(domain)
    msg = "Domain name must only contain lowercase letters, numbers, hyphens and underscore and cannot start with a number or hyphen"
    fail ValidationFailed.new({domain: msg}) unless domain.match?(ALLOWED_DOMAIN_PATTERN)
  end
end
