# frozen_string_literal: true

class Serializers::Web::Lantern < Serializers::Base
  def self.base(pg)
    {
      id: pg.id,
      ubid: pg.ubid,
      path: pg.path,
      name: pg.name,
      state: pg.display_state,
      location: pg.location,
      vm_size: pg.target_vm_size,
      storage_size_gib: pg.target_storage_size_gib
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
