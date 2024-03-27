# frozen_string_literal: true

class Serializers::Web::Lantern < Serializers::Base
  def self.base(pg)
    {
      id: pg.id,
      ubid: pg.ubid,
      path: pg.path,
      name: pg.name,
      state: pg.display_state,
      instance_type: pg.instance_type,
      location: pg.location,
      lantern_version: pg.lantern_version,
      extras_version: pg.extras_version,
      minor_version: pg.minor_version,
      org_id: pg.org_id,
      vm_size: pg.target_vm_size,
      storage_size_gib: pg.target_storage_size_gib,
      domain: pg.gcp_vm.domain
    }
  end

  structure(:default) do |pg|
    base(pg)
  end

  structure(:detailed) do |pg|
    base(pg).merge({
      connection_string: pg.connection_string
    })
  end
end
