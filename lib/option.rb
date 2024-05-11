# frozen_string_literal: true

module Option
  Provider = Struct.new(:name, :display_name) do
    self::GCP = "gcp"
  end
  Providers = [
    [Provider::GCP, "GCP"]
  ].map { |args| [args[0], Provider.new(*args)] }.to_h.freeze

  Location = Struct.new(:provider, :name, :display_name, :visible)
  Locations = [
    [Providers[Provider::GCP], "us-central1", "US Central", true],
    [Providers[Provider::GCP], "us-west2", "US West", true]
  ].map { |args| Location.new(*args) }.freeze

  def self.locations_for_provider(provider, only_visible: true)
    Option::Locations.select { (!only_visible || _1.visible) && (provider.nil? || _1.provider.name == provider) }
  end

  def self.lantern_locations_for_provider(provider)
    Option::Locations.select { _1.provider.name == provider }
  end

  VmSize = Struct.new(:name, :family, :vcpu, :memory, :storage_size_gib) do
    alias_method :display_name, :name
  end
  VmSizes = [1, 2, 4, 8, 16, 32, 64].map {
    VmSize.new("n1-standard-#{_1}", "n1-standard", _1, _1 * 4, (_1 / 2) * 25)
  }.freeze

  LanternSize = Struct.new(:name, :vm_size, :family, :vcpu, :memory, :storage_size_gib) do
    alias_method :display_name, :name
  end

  LanternSizes = [1, 2, 4, 8, 16, 32, 64].map {
    LanternSize.new("n1-standard-#{_1}", "n1-standard-#{_1}", "n1-standard", _1, _1 * 4, _1 * 64)
  }.freeze

  LanternHaOption = Struct.new(:name, :standby_count, :title, :explanation)
  LanternHaOptions = [[LanternResource::HaType::NONE, 0, "No Standbys", "No replication"],
    [LanternResource::HaType::ASYNC, 1, "1 Standby", "Asyncronous replication"],
    [LanternResource::HaType::SYNC, 2, "2 Standbys", "Syncronous replication with quorum"]].map {
    LanternHaOption.new(*_1)
  }.freeze
end
