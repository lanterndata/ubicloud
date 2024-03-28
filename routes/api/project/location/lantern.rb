# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "lantern") do |r|
    @serializer = Serializers::Api::Lantern

    r.on String do |pg_name|
      pg = @project.lantern_servers_dataset.where(location: @location).where { {Sequel[:lantern_server][:name] => pg_name} }.first

      unless pg
        response.status = 404
        r.halt
      end

      @pg = serialize(pg, :detailed)

      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)
        return @pg
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Postgres:delete", pg.id)
        pg.incr_destroy
        response.status = 200
        r.halt
      end

      r.post "reset-user-password" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        Validation.validate_postgres_superuser_password(r.params["original_password"], r.params["repeat_password"])

        pg.update(db_user_password: r.params["original_password"])
        pg.incr_update_user_password

        response.status = 200
        r.halt
      end

      r.post "update-vm" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        #TODO
        DB.transaction do
          if r.params["storage_size_gib"]
            Validation.validate_lantern_size(pg.target_storage_size_gib, r.params["storage_size_gib"])
            pg.update(target_storage_size_gib: r.params["storage_size_gib"])
            GcpVm.dataset.where(id: pg.vm_id).update(storage_size_gib: r.params["storage_size_gib"])
            pg.incr_update_storage_size
          end

          if r.params["size"]
            parsed_size = Validation.validate_lantern_size(r.params["size"])
            pg.update(target_vm_size: parsed_size.vm_size)
            GcpVm.dataset.where(id: pg.vm_id).update(cores: parsed_size.vcpu)
            pg.incr_update_vm_size
          end
        end

        response.status = 200
        r.halt
      end

      r.post "update-extension" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        if r.params["lantern_version"] != pg.lantern_version
          pg.update(lantern_version: r.params["lantern_version"])
          pg.incr_update_rhizome
          pg.incr_update_lantern_extension
        end

        if r.params["extras_version"] != pg.extras_version
          pg.update(extras_version: r.params["extras_version"])
          pg.incr_update_rhizome
          pg.incr_update_extras_extension
        end

        response.status = 200
        r.halt
      end

      r.post "update-image" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        pg.update(lantern_version: r.params["lantern_version"] || pg.lantern_version, extras_version: r.params["extras_version"] || pg.extras_version, minor_version: r.params["minor_version"] || pg.minor_version)
        pg.incr_update_rhizome
        pg.incr_update_image

        response.status = 200
        r.halt
      end

      r.post "add-domain" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        DB.transaction do
          GcpVm.dataset.where(id: pg.vm_id).update(domain: r.params["domain"])
          pg.incr_add_domain
        end
        response.status = 200
        r.halt
      end

      r.post "update-rhizome" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        DB.transaction do
          pg.incr_update_rhizome
        end
        response.status = 200
        r.halt
      end

      r.post "restart" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.incr_restart_server
        response.status = 200
        r.halt
      end

      r.post "start" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.incr_start_server
        response.status = 200
        r.halt
      end

      r.post "stop" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.incr_stop_server
        response.status = 200
        r.halt
      end
    end

    r.get true do
      result = @project.lantern_servers_dataset.where(location: @location).authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
        cursor: r.params["cursor"],
        page_size: r.params["page_size"],
        order_column: r.params["order_column"]
      )

      {
        items: serialize(result[:records]),
        next_cursor: result[:next_cursor],
        count: result[:count]
      }
    end

    r.post true do
      Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
      parsed_size = Validation.validate_lantern_size(r.params["size"])
      Validation.validate_name(r.params["name"])
      Validation.validate_org_id(r.params["org_id"])
      Validation.validate_version(r.params["lantern_version"], "lantern_version")
      Validation.validate_version(r.params["extras_version"], "extras_version")
      Validation.validate_version(r.params["minor_version"], "minor_version")

      domain = r.params["domain"]

      if domain == nil && r.params["subdomain"]
        domain = "#{r.params["subdomain"]}.#{Config.lantern_top_domain}"
      end

      st = Prog::Lantern::LanternServerNexus.assemble(
        project_id: @project.id,
        location: @location,
        name: r.params["name"],
        org_id: r.params["org_id"].to_i,
        instance_type: "writer",
        target_vm_size: parsed_size.vm_size,
        storage_size_gib: r.params["storage_size_gib"] || parsed_size.storage_size_gib,
        lantern_version: r.params["lantern_version"],
        extras_version: r.params["extras_version"],
        minor_version: r.params["minor_version"],
        domain: domain,
        db_name: r.params["db_name"],
        db_user: r.params["db_user"],
        db_user_password: r.params["db_user_password"],
        app_env: r.params["app_env"],
        repl_password: r.params["repl_password"],
        enable_telemetry: r.params["enable_telemetry"],
        enable_debug: r.params["enable_debug"],
        postgres_password: r.params["postgres_password"]
      )
      pg = LanternServer[st.id]

      unless pg
        response.status = 404
        r.halt
      end

      pg = serialize(pg, :detailed)

      pg
    end
  end
end
