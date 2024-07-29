# frozen_string_literal: true

class Serializers::Api::Lantern < Serializers::Base
  def self.base(pg)
    {
      id: pg.id,
      ubid: pg.ubid,
      parent_id: pg.parent_id,
      path: pg.path,
      name: pg.name,
      label: pg.label,
      state: pg.display_state,
      instance_type: pg.representative_server&.instance_type,
      location: pg.location,
      lantern_version: pg.representative_server&.lantern_version,
      extras_version: pg.representative_server&.extras_version,
      minor_version: pg.representative_server&.minor_version,
      org_id: pg.org_id,
      vm_size: pg.representative_server&.target_vm_size,
      storage_size_gib: pg.representative_server&.target_storage_size_gib,
      domain: pg.representative_server&.domain,
      host: pg.representative_server&.hostname,
      debug: pg.debug,
      enable_telemetry: pg.enable_telemetry,
      postgres_password: pg.superuser_password,
      app_env: pg.app_env,
      db_name: pg.db_name,
      db_user: pg.db_user,
      db_user_password: pg.db_user_password,
      repl_user: pg.repl_user,
      repl_password: pg.repl_password
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
