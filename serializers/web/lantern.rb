# frozen_string_literal: true

class Serializers::Web::Lantern < Serializers::Base
  def self.base(pg)
    {
      id: pg.id,
      ubid: pg.ubid,
      path: pg.path,
      name: pg.name,
      label: pg.label,
      state: pg.display_state,
      vm_name: pg.representative_server&.vm&.name,
      primary?: pg.representative_server&.primary?,
      instance_type: pg.representative_server&.instance_type,
      location: pg.location,
      lantern_version: pg.representative_server&.lantern_version,
      extras_version: pg.representative_server&.extras_version,
      minor_version: pg.representative_server&.minor_version,
      org_id: pg.org_id,
      vm_size: pg.representative_server&.target_vm_size,
      storage_size_gib: pg.representative_server&.target_storage_size_gib,
      domain: pg.representative_server&.domain
    }
  end

  structure(:default) do |pg|
    base(pg)
  end

  structure(:detailed) do |pg|
    base(pg).merge({
      connection_string: pg.connection_string,
      servers: pg.servers.map {
                 {
                   id: _1.id,
                   ubid: _1.ubid,
                   state: _1.display_state,
                   primary: _1.primary?,
                   vm_name: _1.vm.name,
                   instance_type: _1.instance_type,
                   lantern_version: _1.lantern_version,
                   extras_version: _1.extras_version,
                   minor_version: _1.minor_version,
                   vm_size: _1.target_vm_size,
                   storage_size_gib: _1.target_storage_size_gib,
                   max_storage_autoresize_gib: _1.max_storage_autoresize_gib,
                   connection_string: _1.connection_string
                 }
               }
    })
  end
end
