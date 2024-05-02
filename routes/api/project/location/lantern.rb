# frozen_string_literal: true

class CloverApi
  hash_branch(:project_location_prefix, "lantern") do |r|
    @serializer = Serializers::Api::Lantern

    r.on String do |pg_name|
      pg = @project.lantern_resources_dataset.where(location: @location).where { {Sequel[:lantern_resource][:name] => pg_name} }.first
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
        if pg.forks.size > 0
          response.status = 409
          return {"error" => "Can not delete resource which has active forks"}
        end
        pg.incr_destroy
        response.status = 200
        r.halt
      end

      r.post "reset-user-password" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        Validation.validate_postgres_superuser_password(r.params["original_password"], r.params["repeat_password"])

        pg.update(db_user_password: r.params["original_password"])
        pg.representative_server.incr_update_user_password

        response.status = 200
        r.halt
      end

      r.post "update-vm" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        DB.transaction do
          if r.params["storage_size_gib"]
            storage_size_gib = r.params["storage_size_gib"].to_i
            Validation.validate_lantern_storage_size(pg.representative_server.target_storage_size_gib, storage_size_gib)
            pg.representative_server.update(target_storage_size_gib: storage_size_gib)
            GcpVm.dataset.where(id: pg.representative_server.vm_id).update(storage_size_gib: storage_size_gib)
            pg.representative_server.incr_update_storage_size
          end

          if r.params["size"]
            parsed_size = Validation.validate_lantern_size(r.params["size"])
            pg.representative_server.update(target_vm_size: parsed_size.vm_size)
            GcpVm.dataset.where(id: pg.representative_server.vm_id).update(cores: parsed_size.vcpu)
            pg.representative_server.incr_update_vm_size
          end
        end

        response.status = 200
        r.halt
      end

      r.post "update-extension" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        if r.params["lantern_version"] != pg.representative_server.lantern_version
          pg.representative_server.update(lantern_version: r.params["lantern_version"])
          pg.representative_server.incr_update_rhizome
          pg.representative_server.incr_update_lantern_extension
        end

        if r.params["extras_version"] != pg.representative_server.extras_version
          pg.representative_server.update(extras_version: r.params["extras_version"])
          pg.representative_server.incr_update_rhizome
          pg.representative_server.incr_update_extras_extension
        end

        response.status = 200
        r.halt
      end

      r.post "update-image" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        pg.representative_server.update(lantern_version: r.params["lantern_version"] || pg.lantern_version, extras_version: r.params["extras_version"] || pg.extras_version, minor_version: r.params["minor_version"] || pg.minor_version)
        pg.representative_server.incr_update_rhizome
        pg.representative_server.incr_update_image

        response.status = 200
        r.halt
      end

      r.post "add-domain" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        DB.transaction do
          pg.representative_server.update(domain: r.params["domain"])
          pg.representative_server.incr_add_domain
        end
        response.status = 200
        r.halt
      end

      r.post "restart" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.representative_server.incr_restart_server
        response.status = 200
        r.halt
      end

      r.post "start" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.representative_server.incr_start_server
        response.status = 200
        r.halt
      end

      r.post "stop" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        pg.representative_server.incr_stop_server
        response.status = 200
        r.halt
      end

      r.get "backups" do
        pg.timeline.backups_with_metadata
          .sort_by { |hsh| hsh[:last_modified] }
          .map { |hsh| {time: hsh[:last_modified], label: pg.timeline.get_backup_label(hsh[:key]), compressed_size: hsh[:compressed_size], uncompressed_size: hsh[:uncompressed_size]} }
      end

      r.post "push-backup" do
        pg.timeline.take_manual_backup
        response.status = 200
        r.halt
      rescue => e
        Clog.emit("Error while pushing backup") { {error: e} }
        response.status = if e.message.include? "Another backup"
          409
        else
          400
        end
        return {"error" => e.message}
      end

      r.post "dissociate-forks" do
        pg.dissociate_forks
        response.status = 200
        r.halt
      end
    end

    r.get true do
      result = @project.lantern_resources_dataset.where(location: @location).authorized(@current_user.id, "Postgres:view").eager(:semaphores, :strand).paginated_result(
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
  end
end
