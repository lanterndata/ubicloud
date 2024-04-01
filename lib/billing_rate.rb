# frozen_string_literal: true

require "yaml"

class BillingRate
  def self.rates
    @@rates ||= YAML.load_file("config/billing_rates.yml")
  end

  def self.line_item_description(resource_type, resource_family, amount)
    case resource_type
    when "VmCores"
      "#{resource_family}-#{(amount * 2).to_i} Virtual Machine"
    when "PostgresCores"
      "#{resource_family}-#{(amount * 2).to_i} backed PostgreSQL Database"
    when "PostgresStandbyCores"
      "#{resource_family}-#{(amount * 2).to_i} backed PostgreSQL Database (HA Standby)"
    when "PostgresStorage"
      "#{amount.to_i} GiB Storage for PostgreSQL Database"
    when "PostgresStandbyStorage"
      "#{amount.to_i} GiB Storage for PostgreSQL Database (HA Standby)"
    else
      fail "BUG: Unknown resource type for line item description"
    end
  end
end
