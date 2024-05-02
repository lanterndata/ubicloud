# frozen_string_literal: true

class CloverWeb
  hash_branch(:project_location_prefix, "lantern") do |r|
    @serializer = Serializers::Web::Lantern

    r.on String do |pg_name|
      pg = @project.lantern_resources_dataset.where(location: @location).where { {Sequel[:lantern_resource][:name] => pg_name} }.first

      unless pg
        response.status = 404
        r.halt
      end
      @pg = serialize(pg, :detailed)

      r.get true do
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)
        view "lantern/show"
      end

      r.delete true do
        Authorization.authorize(@current_user.id, "Postgres:delete", pg.id)
        pg.incr_destroy
        return {message: "Deleting #{pg.name}"}.to_json
      end

      r.post "reset-user-password" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        Validation.validate_postgres_superuser_password(r.params["original_password"], r.params["repeat_password"])

        pg.update(db_user_password: r.params["original_password"])
        pg.representative_server.incr_update_user_password

        flash["notice"] = "The superuser password will be updated in a few seconds"
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update-extension" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        if r.params["lantern_version"] != pg.representative_server.lantern_version
          pg.representative_server.update(lantern_version: r.params["lantern_version"])
          pg.representative_server.incr_update_lantern_extension
        end

        if r.params["extras_version"] != pg.representative_server.extras_version
          pg.representative_server.update(extras_version: r.params["extras_version"])
          pg.representative_server.incr_update_extras_extension
        end

        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update-image" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)

        pg.representative_server.update(lantern_version: r.params["img_lantern_version"] || pg.representative_server.lantern_version, extras_version: r.params["img_extras_version"] || pg.representative_server.extras_version, minor_version: r.params["img_minor_version"] || pg.representative_server.minor_version)
        pg.representative_server.incr_update_image
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "add-domain" do
        Authorization.authorize(@current_user.id, "Postgres:edit", pg.id)
        DB.transaction do
          pg.representative_server.update(domain: r.params["domain"])
          pg.representative_server.incr_add_domain
        end
        r.redirect "#{@project.path}#{pg.path}"
      end

      r.post "update-vm" do
        Authorization.authorize(@current_user.id, "Postgres:create", @project.id)
        Authorization.authorize(@current_user.id, "Postgres:view", pg.id)

        DB.transaction do
          if r.params["storage_size_gib"].to_i != pg.representative_server.target_storage_size_gib
            storage_size_gib = r.params["storage_size_gib"].to_i
            Validation.validate_lantern_storage_size(pg.representative_server.target_storage_size_gib, storage_size_gib)
            pg.representative_server.update(target_storage_size_gib: storage_size_gib)
            GcpVm.dataset.where(id: pg.representative_server.vm_id).update(storage_size_gib: storage_size_gib)
            pg.representative_server.incr_update_storage_size
          end

          if r.params["size"] != pg.representative_server.target_vm_size
            parsed_size = Validation.validate_lantern_size(r.params["size"])
            pg.representative_server.update(target_vm_size: parsed_size.vm_size)
            GcpVm.dataset.where(id: pg.representative_server.vm_id).update(cores: parsed_size.vcpu)
            pg.representative_server.incr_update_vm_size
          end
        end

        flash["notice"] = "'#{pg.name}' will be updated in a few minutes"
        r.redirect "#{@project.path}#{pg.path}"
      end
      # r.post "restart" do
      #   Authorization.authorize(@current_user.id, "postgres:edit", pg.id)
      #   pg.gcp_vm.incr_restart
      #   r.redirect "#{@project.path}#{pg.path}"
      # end
    end
  end
end
